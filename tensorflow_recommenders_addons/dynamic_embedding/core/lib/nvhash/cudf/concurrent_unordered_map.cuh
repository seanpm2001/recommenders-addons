/*
 * Copyright (c) 2017-2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef CONCURRENT_UNORDERED_MAP_CUH
#define CONCURRENT_UNORDERED_MAP_CUH

#include <iterator>
#include <type_traits>
#include <cassert>
#include <iostream>
#include <thrust/pair.h>


#include "managed_allocator.cuh"
#include "managed.cuh"
#include "hash_functions.cuh"

// TODO: replace this with CUDA_TRY and propagate the error
#ifndef CUDA_RT_CALL
#define CUDA_RT_CALL( call ) 									   \
{                                                                                                  \
    cudaError_t cudaStatus = call;                                                                 \
    if ( cudaSuccess != cudaStatus ) {                                                             \
        fprintf(stderr, "ERROR: CUDA RT call \"%s\" in line %d of file %s failed with %s (%d).\n", \
                        #call, __LINE__, __FILE__, cudaGetErrorString(cudaStatus), cudaStatus);    \
        exit(1);										   \
    }												   \
}
#endif



// TODO: can we do this more efficiently?
__inline__ __device__ int8_t atomicCAS(int8_t* address, int8_t compare, int8_t val)
{
  int32_t *base_address = (int32_t*)((char*)address - ((size_t)address & 3));
  int32_t int_val = (int32_t)val << (((size_t)address & 3) * 8);
  int32_t int_comp = (int32_t)compare << (((size_t)address & 3) * 8);
  return (int8_t)atomicCAS(base_address, int_comp, int_val);
}

// TODO: can we do this more efficiently?
/*__inline__ __device__ int16_t atomicCAS(int16_t* address, int16_t compare, int16_t val)
{
  int32_t *base_address = (int32_t*)((char*)address - ((size_t)address & 2));
  int32_t int_val = (int32_t)val << (((size_t)address & 2) * 8);
  int32_t int_comp = (int32_t)compare << (((size_t)address & 2) * 8);
  return (int16_t)atomicCAS(base_address, int_comp, int_val);
}*/

__inline__ __device__ int64_t atomicCAS(int64_t* address, int64_t compare, int64_t val)
{
  return (int64_t)atomicCAS((unsigned long long*)address, (unsigned long long)compare, (unsigned long long)val);
}

__inline__ __device__ uint64_t atomicCAS(uint64_t* address, uint64_t compare, uint64_t val)
{
  return (uint64_t)atomicCAS((unsigned long long*)address, (unsigned long long)compare, (unsigned long long)val);
}

__inline__ __device__ long long int atomicCAS(long long int* address, long long int compare, long long int val)
{
  return (long long int)atomicCAS((unsigned long long*)address, (unsigned long long)compare, (unsigned long long)val);
}

__inline__ __device__ double atomicCAS(double* address, double compare, double val)
{
  return __longlong_as_double(atomicCAS((unsigned long long int*)address, __double_as_longlong(compare), __double_as_longlong(val)));
}

__inline__ __device__ float atomicCAS(float* address, float compare, float val)
{
  return __int_as_float(atomicCAS((int*)address, __float_as_int(compare), __float_as_int(val)));
}

__inline__ __device__ int64_t atomicAdd(long long* address, const long long val)
{
  return (int64_t) atomicAdd((unsigned long long*)address, (const unsigned long long)val);
}

__inline__ __device__ int64_t atomicAdd(int64_t* address, const int64_t val)
{
  return (int64_t) atomicAdd((unsigned long long*)address, (const unsigned long long)val);
}

__inline__ __device__ uint64_t atomicAdd(uint64_t* address,  const uint64_t val)
{
  return (uint64_t) atomicAdd((unsigned long long*)address, (const unsigned long long)val);
}

__inline__ __device__ signed char atomicAdd(signed char* address, const signed char val)
{
  int *base_address = (int*)((char*)address - ((size_t)address & 3));
  int int_val = (int)val << (((size_t)address & 3) * 8);

  return (signed char) atomicAdd((int*)base_address, (const int)int_val);
}

typedef unsigned int uint32;
typedef unsigned short uint16;

__inline__ __device__ uint32 add_to_low_half(uint32 val, float x) {
  Eigen::half low_half;
  low_half.x = static_cast<uint16>(val & 0xffffu);
  low_half = static_cast<Eigen::half>(static_cast<float>(low_half) + x);
  return (val & 0xffff0000u) | low_half.x;
}

__inline__ __device__ uint32 add_to_high_half(uint32 val, float x) {
  Eigen::half high_half;
  high_half.x = static_cast<uint16>(val >> 16);
  high_half = static_cast<Eigen::half>(static_cast<float>(high_half) + x);
  return (val & 0xffffu) | (high_half.x << 16);
}

__device__ __forceinline__ Eigen::half atomicAdd(Eigen::half* address, const Eigen::half val) {
  float val_as_float(val);
  intptr_t address_int = reinterpret_cast<intptr_t>(address);
  if ((address_int & 0x2) == 0) {
    // The half is in the first part of the uint32 (lower 16 bits).
    uint32* address_as_uint32 = reinterpret_cast<uint32*>(address);
    assert(((intptr_t)address_as_uint32 & 0x3) == 0);
    uint32 old = *address_as_uint32, assumed;

    do {
      assumed = old;
      old = atomicCAS(address_as_uint32, assumed,
                      add_to_low_half(assumed, val_as_float));

      // Note: uses integer comparison to avoid hang in case of NaN
    } while (assumed != old);

    Eigen::half ret;
    ret.x = old & 0xffffu;
    return ret;
  } else {
    // The half is in the second part of the uint32 (upper 16 bits).
    uint32* address_as_uint32 = reinterpret_cast<uint32*>(address_int - 2);
    assert(((intptr_t)address_as_uint32 & 0x3) == 0);
    uint32 old = *address_as_uint32, assumed;

    do {
      assumed = old;
      old = atomicCAS(address_as_uint32, assumed,
                      add_to_high_half(assumed, val_as_float));

      // Note: uses integer comparison to avoid hang in case of NaN
    } while (assumed != old);

    Eigen::half ret;
    ret.x = old >> 16;
    return ret;
  }
}

template<typename pair_type>
__forceinline__
__device__ pair_type load_pair_vectorized( const pair_type* __restrict__ const ptr )
{
    if ( sizeof(uint4) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            uint4       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0,0,0,0};
        converter.vec_val = *reinterpret_cast<const uint4*>(ptr);
        return converter.pair_val;
    } else if ( sizeof(uint2) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            uint2       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0,0};
        converter.vec_val = *reinterpret_cast<const uint2*>(ptr);
        return converter.pair_val;
    } else if ( sizeof(int) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            int         vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0};
        converter.vec_val = *reinterpret_cast<const int*>(ptr);
        return converter.pair_val;
    } else if ( sizeof(short) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            short       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0};
        converter.vec_val = *reinterpret_cast<const short*>(ptr);
        return converter.pair_val;
    } else {
        return *ptr;
    }
}
 
template<typename pair_type>
__forceinline__
__device__ void store_pair_vectorized( pair_type* __restrict__ const ptr, const pair_type val )
{
    if ( sizeof(uint4) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            uint4       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0,0,0,0};
        converter.pair_val = val;
        *reinterpret_cast<uint4*>(ptr) = converter.vec_val;
    } else if ( sizeof(uint2) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            uint2       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0,0};
        converter.pair_val = val;
        *reinterpret_cast<uint2*>(ptr) = converter.vec_val;
    } else if ( sizeof(int) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            int         vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0};
        converter.pair_val = val;
        *reinterpret_cast<int*>(ptr) = converter.vec_val;
    } else if ( sizeof(short) == sizeof(pair_type) ) {
        union pair_type2vec_type
        {
            short       vec_val;
            pair_type   pair_val;
        };
        pair_type2vec_type converter = {0};
        converter.pair_val = val;
        *reinterpret_cast<short*>(ptr) = converter.vec_val;
    } else {
        *ptr = val;
    }
}

template<typename value_type, typename size_type, typename key_type, typename elem_type>
__global__ void init_hashtbl( //Init every entry of the table with <unused_key, unused_value> pair
    value_type* __restrict__ const hashtbl_values,
    volatile int32_t * valid_marker,
    //lock_type* bucket_lock,
    const size_type n,
    const key_type key_val,
    const elem_type elem_val)
{
    const size_type idx = blockIdx.x * blockDim.x + threadIdx.x;
    if ( idx < n )
    {
        store_pair_vectorized( hashtbl_values + idx, thrust::make_pair( key_val, elem_val ) ); // Simply store every element a <K, V> pair
        valid_marker[idx] = true; // Every entry is valid as initial state
        //bucket_lock[idx] = 0; // Every entry is unlocked as initial state
    }
}

template <typename T>
struct equal_to
{
    using result_type = bool;
    using first_argument_type = T;
    using second_argument_type = T;
    __forceinline__
    __host__ __device__ constexpr bool operator()(const first_argument_type &lhs, const second_argument_type &rhs) const 
    {
        return lhs == rhs;
    }
};

template<typename T>
struct iterator_with_index{
    T Iterator;
    size_t current_index;
    __host__ __device__ explicit iterator_with_index(T& input_iterator, size_t input_index)
    : Iterator(input_iterator), current_index(input_index)
    {}
};

template<typename Iterator>
class cycle_iterator_adapter {
public:
    using value_type = typename std::iterator_traits<Iterator>::value_type; 
    using difference_type = typename std::iterator_traits<Iterator>::difference_type;
    using pointer = typename std::iterator_traits<Iterator>::pointer;
    using reference = typename std::iterator_traits<Iterator>::reference;
    using iterator_type = Iterator;
    
    cycle_iterator_adapter() = delete;
    
    __host__ __device__ explicit cycle_iterator_adapter( const iterator_type& begin, const iterator_type& end, const iterator_type& current )
        : m_begin( begin ), m_end( end ), m_current( current )
    {}
    
    __host__ __device__ cycle_iterator_adapter& operator++()
    {
        if ( m_end == (m_current+1) )
            m_current = m_begin;
        else
            ++m_current;
        return *this;
    }
    
    __host__ __device__ const cycle_iterator_adapter& operator++() const
    {
        if ( m_end == (m_current+1) )
            m_current = m_begin;
        else
            ++m_current;
        return *this;
    }
    
    __host__ __device__ cycle_iterator_adapter& operator++(int)
    {
        cycle_iterator_adapter<iterator_type> old( m_begin, m_end, m_current);
        if ( m_end == (m_current+1) )
            m_current = m_begin;
        else
            ++m_current;
        return old;
    }
    
    __host__ __device__ const cycle_iterator_adapter& operator++(int) const
    {
        cycle_iterator_adapter<iterator_type> old( m_begin, m_end, m_current);
        if ( m_end == (m_current+1) )
            m_current = m_begin;
        else
            ++m_current;
        return old;
    }
    
    __host__ __device__ bool equal(const cycle_iterator_adapter<iterator_type>& other) const
    {
        return m_current == other.m_current && m_begin == other.m_begin && m_end == other.m_end;
    }
    
    __host__ __device__ reference& operator*()
    {
        return *m_current;
    }
    
    __host__ __device__ const reference& operator*() const
    {
        return *m_current;
    }

    __host__ __device__ const pointer operator->() const
    {
        return m_current.operator->();
    }
    
    __host__ __device__ pointer operator->()
    {
        return m_current;
    }

    __host__ __device__ iterator_type getter() const{
        return m_current;
    }
    
private:
    iterator_type m_current;
    iterator_type m_begin;
    iterator_type m_end;
};

template <class T>
__host__ __device__ bool operator==(const cycle_iterator_adapter<T>& lhs, const cycle_iterator_adapter<T>& rhs)
{
    return lhs.equal(rhs);
}

template <class T>
__host__ __device__ bool operator!=(const cycle_iterator_adapter<T>& lhs, const cycle_iterator_adapter<T>& rhs)
{
    return !lhs.equal(rhs);
}

/**
 * Does support concurrent insert, but not concurrent insert and probping.
 *
 * TODO:
 *  - add constructor that takes pointer to hash_table to avoid allocations
 *  - extend interface to accept streams
 */
template <typename Key,
          typename Element,
          Key unused_key,
          size_t DIM,
          typename Hasher = default_hash<Key>,
          typename Equality = equal_to<Key>,
          typename Allocator = managed_allocator<thrust::pair<Key, Element> >,
          bool count_collisions = false>
class concurrent_unordered_map : public managed
{

public:
    using size_type = size_t;
    using hasher = Hasher;
    using key_equal = Equality;
    using allocator_type = Allocator;
    using key_type = Key;
    using value_type = thrust::pair<Key, Element>;
    using mapped_type = Element;
    using iterator = cycle_iterator_adapter<value_type*>;
    using const_iterator = const cycle_iterator_adapter<value_type*>;

private:
    union pair2longlong
    {
        unsigned long long int  longlong;
        value_type              pair;
    };
    
public:
    concurrent_unordered_map(const concurrent_unordered_map&) = delete;
    concurrent_unordered_map& operator=(const concurrent_unordered_map&) = delete;
    explicit concurrent_unordered_map(size_type n,
                                      const mapped_type unused_element,
                                      const Hasher& hf = hasher(),
                                      const Equality& eql = key_equal(),
                                      const allocator_type& a = allocator_type())
        : m_hf(hf), m_equal(eql), m_allocator(a), m_hashtbl_size(n), m_hashtbl_capacity(n), m_collisions(0), m_unused_element(unused_element)
    { // allocate the raw data of hash table: m_hashtbl_values,pre-alloc it on current GPU if UM.
        m_hashtbl_values = m_allocator.allocate( m_hashtbl_capacity );
        // Allocate marker and lock buffer
        CUDA_RT_CALL( cudaMallocManaged((void**)&valid_marker, m_hashtbl_capacity * sizeof(*valid_marker)) );
        //CUDA_RT_CALL( cudaMalloc((void**)&bucket_lock, m_hashtbl_capacity * sizeof(*bucket_lock)) );
        constexpr int block_size = 128;
        {
            cudaPointerAttributes hashtbl_values_ptr_attributes;
            cudaError_t status = cudaPointerGetAttributes( &hashtbl_values_ptr_attributes, m_hashtbl_values );
            
#if CUDART_VERSION >= 10000
            if ( cudaSuccess == status && hashtbl_values_ptr_attributes.type == cudaMemoryTypeManaged )
#else
            if ( cudaSuccess == status && hashtbl_values_ptr_attributes.isManaged )
#endif
            {
                int dev_id = 0;
                CUDA_RT_CALL( cudaGetDevice( &dev_id ) );
                CUDA_RT_CALL( cudaMemPrefetchAsync(m_hashtbl_values, m_hashtbl_size*sizeof(value_type), dev_id, 0) );
            }
        }
        // Initialize kernel, set all entry to unused <K,V>
        init_hashtbl<<<((m_hashtbl_size-1)/block_size)+1,block_size>>>( m_hashtbl_values, valid_marker, m_hashtbl_size, unused_key, m_unused_element );
        // CUDA_RT_CALL( cudaGetLastError() );
        CUDA_RT_CALL( cudaStreamSynchronize(0) );
        CUDA_RT_CALL( cudaGetLastError() );
    }
    
    ~concurrent_unordered_map()
    {
        m_allocator.deallocate( m_hashtbl_values, m_hashtbl_capacity );
        // De-allocate marker and lock buffer
        CUDA_RT_CALL( cudaFree((void*)valid_marker) );
        //CUDA_RT_CALL( cudaFree(bucket_lock) );
    }
    
    __host__ __device__ iterator begin()
    {
        return iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,m_hashtbl_values );
    }
    __host__ __device__ const_iterator begin() const
    {
        return const_iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,m_hashtbl_values );
    }
    __host__ __device__ iterator end()
    {
        return iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,m_hashtbl_values+m_hashtbl_size );
    }
    __host__ __device__ const_iterator end() const
    {
        return const_iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,m_hashtbl_values+m_hashtbl_size );
    }
    __host__ __device__ size_type size() const
    {
        return m_hashtbl_size;
    }
    __host__ __device__ value_type* data() const
    {
      return m_hashtbl_values;
    }
    
    __forceinline__
    static constexpr __host__ __device__ key_type get_unused_key()
    {
        return unused_key;
    }

    // Generic update of a hash table value for any aggregator
    /*template <typename aggregation_type>
    __forceinline__  __device__
    void update_existing_value(volatile mapped_type & existing_value, volatile value_type & insert_pair, aggregation_type)
    {
      // update without CAS
      existing_value = insert_pair.second;
    }*/


    __forceinline__  __device__
    void accum_existing_value_atomic(mapped_type & existing_value, const mapped_type & accum_pair)
    {
      const mapped_type & accumulator = accum_pair;

      for(size_t i = 0; i < DIM; i++){
        atomicAdd(&(existing_value.value[i]), accumulator.value[i]);
      }
    }

    // TODO Overload atomicAdd for 1 byte and 2 byte types, until then, overload specifically for the types
    // where atomicAdd already has an overload. Otherwise the generic update_existing_value will be used.
    // Specialization for COUNT aggregator
    /*
    __forceinline__ __host__ __device__
    void update_existing_value(mapped_type & existing_value, value_type const & insert_pair, count_op<int32_t> op)
    {
      atomicAdd(&existing_value, static_cast<mapped_type>(1));
    }
    // Specialization for COUNT aggregator
    __forceinline__ __host__ __device__
    void update_existing_value(mapped_type & existing_value, value_type const & insert_pair, count_op<int64_t> op)
    {
      atomicAdd(&existing_value, static_cast<mapped_type>(1));
    }
    // Specialization for COUNT aggregator
    __forceinline__ __host__ __device__
    void update_existing_value(mapped_type & existing_value, value_type const & insert_pair, count_op<float> op)
    {
      atomicAdd(&existing_value, static_cast<mapped_type>(1));
    }
    // Specialization for COUNT aggregator
    __forceinline__ __host__ __device__
    void update_existing_value(mapped_type & existing_value, value_type const & insert_pair, count_op<double> op)
    {
      atomicAdd(&existing_value, static_cast<mapped_type>(1));
    }
    */

    /* --------------------------------------------------------------------------*/
    /** 
     * @Synopsis  Inserts a new (key, value) pair. If the key already exists in the map
                  an aggregation operation is performed with the new value and existing value.
                  E.g., if the aggregation operation is 'max', then the maximum is computed
                  between the new value and existing value and the result is stored in the map.
     * 
     * @Param[in] x The new (key, value) pair to insert
     * @Param[in] op The aggregation operation to perform
     * @Param[in] keys_equal An optional functor for comparing two keys 
     * @Param[in] precomputed_hash Indicates if a precomputed hash value is being passed in to use
     * to determine the write location of the new key
     * @Param[in] precomputed_hash_value The precomputed hash value
     * @tparam aggregation_type A functor for a binary operation that performs the aggregation
     * @tparam comparison_type A functor for comparing two keys
     * 
     * @Returns An iterator to the newly inserted key,value pair
     */
    /* ----------------------------------------------------------------------------*/
    /*template<typename aggregation_type,
             class comparison_type = key_equal,
             typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ iterator insert(const value_type& x, 
                               aggregation_type op,
                               comparison_type keys_equal = key_equal(),
                               bool precomputed_hash = false,
                               hash_value_type precomputed_hash_value = 0)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;

        hash_value_type hash_value{0};

        // If a precomputed hash value has been passed in, then use it to determine
        // the write location of the new key
        if(true == precomputed_hash)
        {
          hash_value = precomputed_hash_value;
        }
        // Otherwise, compute the hash value from the new key
        else
        {
          hash_value = m_hf(x.first);
        }

        size_type current_index         = hash_value % hashtbl_size;
        value_type *current_hash_bucket = &(hashtbl_values[current_index]);

        const key_type insert_key = x.first;
        
        bool insert_success = false;
        
        size_type counter = 0;
        while (false == insert_success) {
            if (counter++ >= hashtbl_size) {
                return end();
            }

          key_type& existing_key = current_hash_bucket->first;
          mapped_type& existing_value = current_hash_bucket->second;

          // Try and set the existing_key for the current hash bucket to insert_key
          const key_type old_key = atomicCAS( &existing_key, unused_key, insert_key);

          // If old_key == unused_key, the current hash bucket was empty
          // and existing_key was updated to insert_key by the atomicCAS. 
          // If old_key == insert_key, this key has already been inserted. 
          // In either case, perform the atomic aggregation of existing_value and insert_value
          // Because the hash table is initialized with the identity value of the aggregation
          // operation, it is safe to perform the operation when the existing_value still 
          // has its initial value
          // TODO: Use template specialization to make use of native atomic functions
          // TODO: How to handle data types less than 32 bits?
          if ( keys_equal( unused_key, old_key ) || keys_equal(insert_key, old_key) ) {

            update_existing_value(existing_value, x, op);

            insert_success = true;
          }

          current_index = (current_index+1)%hashtbl_size;
          current_hash_bucket = &(hashtbl_values[current_index]);
        }
        
        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, current_hash_bucket);
    }*/
    
    /* This function is not currently implemented
    __forceinline__
    __host__ __device__ iterator insert(const value_type& x)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;
        const size_type key_hash        = m_hf( x.first );
        size_type hash_tbl_idx          = key_hash%hashtbl_size;
        
        value_type* it = 0;
        
        while (0 == it) {
            value_type* tmp_it = hashtbl_values + hash_tbl_idx;
#ifdef __CUDA_ARCH__
            if ( std::numeric_limits<key_type>::is_integer && std::numeric_limits<mapped_type>::is_integer &&
                 sizeof(unsigned long long int) == sizeof(value_type) )
            {
                pair2longlong converter = {0ull};
                converter.pair = thrust::make_pair( unused_key, m_unused_element );
                const unsigned long long int unused = converter.longlong;
                converter.pair = x;
                const unsigned long long int value = converter.longlong;
                const unsigned long long int old_val = atomicCAS( reinterpret_cast<unsigned long long int*>(tmp_it), unused, value );
                if ( old_val == unused ) {
                    it = tmp_it;
                }
                else if ( count_collisions )
                {
                    atomicAdd( &m_collisions, 1 );
                }
            } else {
                const key_type old_key = atomicCAS( &(tmp_it->first), unused_key, x.first );
                if ( m_equal( unused_key, old_key ) ) {
                    (m_hashtbl_values+hash_tbl_idx)->second = x.second;
                    it = tmp_it;
                }
                else if ( count_collisions )
                {
                    atomicAdd( &m_collisions, 1 );
                }
            }
#else
            
            #pragma omp critical
            {
                if ( m_equal( unused_key, tmp_it->first ) ) {
                    hashtbl_values[hash_tbl_idx] = thrust::make_pair( x.first, x.second );
                    it = tmp_it;
                }
            }
#endif
            hash_tbl_idx = (hash_tbl_idx+1)%hashtbl_size;
        }
        
        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size,it);
    }
    */
/*
    template<typename aggregation_type,
             class comparison_type = key_equal,
             typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ iterator insert(const value_type& x, 
                               aggregation_type op,
                               comparison_type keys_equal = key_equal(),
                               bool precomputed_hash = false,
                               hash_value_type precomputed_hash_value = 0)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;

        hash_value_type hash_value{0};

        // If a precomputed hash value has been passed in, then use it to determine
        // the write location of the new key
        if(true == precomputed_hash)
        {
          hash_value = precomputed_hash_value;
        }
        // Otherwise, compute the hash value from the new key
        else
        {
          hash_value = m_hf(x.first);
        }

        size_type current_index         = hash_value % hashtbl_size;
        value_type *current_hash_bucket = &(hashtbl_values[current_index]);

        const key_type insert_key = x.first;
        
        bool insert_success = false;

        bool founded = false;
        
        size_type counter = 0;

        while (false == insert_success) {
            // Walked through the whole table: full
            if (counter++ >= hashtbl_size) {
                return end();
            }
        
            // Lock the bucket to exclusively access the bucket
            lock_bucket(current_index);

            volatile key_type& existing_key = current_hash_bucket->first;
            mapped_type& existing_value = current_hash_bucket->second;

            // Situation #1: Current bucket is empty key.
            if( unused_key == existing_key ){

                existing_key = insert_key; // Insert the key

                existing_value = x.second; // Insert the value

                founded = true; // Find is complete: we have know that the <k,v> is not inside the hashtable

                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
            }
            // Situation #2: Current bucket is already the insert key and is a valid bucket(not been deleted)
            else if( valid_marker[current_index] ){
                if( insert_key == existing_key ){

                    existing_value = x.second; // Update the value to latest(i.e "set")

                    founded = true; // Find is complete: we have know that the <k,v> is inside the hashtable

                    insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
                }
            }
            else {
                // Situation #3: Current bucket is already the insert key but is a invalid bucket(been deleted)
                if( insert_key == existing_key ){

                    existing_value = x.second; // Update the value to latest(i.e "set")

                    valid_marker[current_index] = true; // Validate the current bucket

                    founded = true; // Find is complete: we have know that the <k,v> is not inside the hashtable

                    insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
                }
                // Situation #4: Current bucket is not the insert key and is a invalid bucket(been deleted)
                else{

                    existing_key = insert_key; // Insert the key

                    existing_value = x.second; // Insert the value

                    valid_marker[current_index] = true; // Validate the current bucket

                    // We have not found the key yet, maybe the key is not presented, maybe it is somewhere afterward.
                    
                    insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
                }
            }
            // Situation #5: Current bucket is a valid bucket and is not the insert key(already occupied): move to next bucket.

            // Finish access the bucket, unlock it.
            unlock_bucket(current_index);

            // Move to access the next bucket.
            current_index = (current_index+1)%hashtbl_size;

            current_hash_bucket = &(hashtbl_values[current_index]);
          
        }

        // Record the inserted position for returned iterator
        value_type* return_hash_bucket = current_hash_bucket;

        // If we have not found the key, we must keep searching to make sure there is no duplicated key in the hashtable
        while( founded == false ){

            // Walked through the rest of the table and couldn't find the key
            if (counter++ >= hashtbl_size) {
                return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, return_hash_bucket);
            }

            // Lock the bucket to exclusively access the bucket
            lock_bucket(current_index);

            volatile key_type& existing_key = current_hash_bucket->first;
            //volatile mapped_type& existing_value = current_hash_bucket->second;

            // If find a unused bucket: we have know that the <k,v> is not inside the hashtable
            if( unused_key == existing_key ){
                founded = true;
            }
            else if( insert_key == existing_key ){
                // If find the valid insert key: we have know that the <k,v> is inside the hashtable, invalidate it.
                if( valid_marker[current_index] ){

                    valid_marker[current_index] = false;

                }
                // If find the invalid insert key: we have know that the <k,v> is not inside the hashtable.
                founded = true;
            }

            //If find bucket of other keys, keep searching.

            // Finish access the bucket, unlock it.
            unlock_bucket(current_index);
            
            // Move to access the next bucket.
            current_index = (current_index+1)%hashtbl_size;

            current_hash_bucket = &(hashtbl_values[current_index]);

        }

        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, return_hash_bucket);
    }*/

    template<typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ iterator insert(const value_type& x, 
                               bool precomputed_hash = false,
                               hash_value_type precomputed_hash_value = 0)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;

        hash_value_type hash_value{0};

        // If a precomputed hash value has been passed in, then use it to determine
        // the write location of the new key
        if(true == precomputed_hash)
        {
          hash_value = precomputed_hash_value;
        }
        // Otherwise, compute the hash value from the new key
        else
        {
          hash_value = m_hf(x.first);
        }

        size_type current_index         = hash_value % hashtbl_size;
        value_type *current_hash_bucket = &(hashtbl_values[current_index]);

        const key_type insert_key = x.first;
        
        bool insert_success = false;
        
        size_type counter = 0;

        while (false == insert_success) {
            // Walked through the whole table: full
            if (counter++ >= hashtbl_size) {
                return end();
            }
        
            // Lock the bucket to exclusively access the bucket, we do not use lock-based approach
            // lock_bucket(current_index);

            volatile key_type& existing_key = current_hash_bucket->first;
            mapped_type& existing_value = current_hash_bucket->second;

            // Situation #1: Current bucket is empty key or invalid, we just need to insert. Key is guarantee by user not found in the table.

            /*if( unused_key == existing_key || valid_marker[current_index] == false ){

                existing_key = insert_key; // Insert the key

                existing_value = x.second; // Insert the value

                valid_marker[current_index] = true; // Validate the current bucket

                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
            }*/

            const key_type old_key = atomicCAS( (key_type *)&existing_key, unused_key, insert_key);

            if( unused_key == old_key || x.first == old_key ){

                existing_value = x.second; // Insert the value

                //valid_marker[current_index] = true; // Validate the current bucket (actually it is always true if it is unused key)

                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
            }
            else{
                const int32_t old_valid = atomicCAS((int32_t *)(valid_marker + current_index), (int32_t)false, (int32_t)true);

                if( false == old_valid ){

                    existing_key = insert_key; // Insert the key

                    existing_value = x.second; // Insert the value

                    insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
                }
            }
            
            // Situation #2: Current bucket is a valid bucket and is not unused key(already occupied): move to next bucket.

            // Finish access the bucket, unlock it. We do not use lock-based approach
            // unlock_bucket(current_index);

            // Move to access the next bucket.
            current_index = (current_index+1)%hashtbl_size;

            current_hash_bucket = &(hashtbl_values[current_index]);
          
        }

        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, current_hash_bucket);
    }
                               
    template<typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ iterator accum(const key_type& key, const mapped_type& vals, const bool &exist, 
                               bool precomputed_hash = false,
                               hash_value_type precomputed_hash_value = 0)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;

        hash_value_type hash_value{0};

        // If a precomputed hash value has been passed in, then use it to determine
        // the write location of the new key
        if(true == precomputed_hash)
        {
          hash_value = precomputed_hash_value;
        }
        // Otherwise, compute the hash value from the new key
        else
        {
          hash_value = m_hf(key);
        }

        size_type current_index         = hash_value % hashtbl_size;
        value_type *current_hash_bucket = &(hashtbl_values[current_index]);
        
        bool insert_success = false;
        
        size_type counter = 0;

        while (false == insert_success) {
            // Walked through the whole table: full
            if (counter++ >= hashtbl_size) {
                return end();
            }
        
            // Lock the bucket to exclusively access the bucket, we do not use lock-based approach
            // lock_bucket(current_index);

            volatile key_type& existing_key = current_hash_bucket->first;
            mapped_type& existing_value = current_hash_bucket->second;

            // Situation #1: Current bucket is empty key or invalid, we just need to insert. Key is guarantee by user not found in the table.

            /*if( unused_key == existing_key || valid_marker[current_index] == false ){

                existing_key = insert_key; // Insert the key

                existing_value = x.second; // Insert the value

                valid_marker[current_index] = true; // Validate the current bucket

                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
            }*/

            const key_type old_key = atomicCAS( (key_type *)&existing_key, unused_key, key);

            if( unused_key == old_key){
                if(!exist){
                    existing_value = vals; // Insert the value
                }

                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
            } else if(key == old_key){
                if(exist) {
                    accum_existing_value_atomic(existing_value, vals); // Accumlate x to the value
                }
                insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
              
            } else {
                const int32_t old_valid = atomicCAS((int32_t *)(valid_marker + current_index), (int32_t)false, (int32_t)true);

                if( false == old_valid){
                    if(!exist) {
                        existing_key = key; // Insert the key

                        existing_value = vals; // Insert the value
                    }
                    insert_success = true; // Insert is complete: we have found a place to hold the <k,v>
                }
                  
            }
            
            // Situation #2: Current bucket is a valid bucket and is not unused key(already occupied): move to next bucket.

            // Finish access the bucket, unlock it. We do not use lock-based approach
            // unlock_bucket(current_index);

            // Move to access the next bucket.
            current_index = (current_index+1)%hashtbl_size;

            current_hash_bucket = &(hashtbl_values[current_index]);
          
        }

        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, current_hash_bucket);
    }

    /*__forceinline__
    __host__ __device__ const_iterator find(const key_type& k ) const
    {
        size_type key_hash = m_hf( k );
        size_type hash_tbl_idx = key_hash%m_hashtbl_size;
        
        value_type* begin_ptr = 0;
        
        size_type counter = 0;
        while ( 0 == begin_ptr ) {
            value_type* tmp_ptr = m_hashtbl_values + hash_tbl_idx;
            const key_type tmp_val = tmp_ptr->first;
            if ( m_equal( k, tmp_val ) ) {
                begin_ptr = tmp_ptr;
                break;
            }
            if ( m_equal( unused_key , tmp_val ) || counter > m_hashtbl_size ) {
                begin_ptr = m_hashtbl_values + m_hashtbl_size;
                break;
            }
            hash_tbl_idx = (hash_tbl_idx+1)%m_hashtbl_size;
            ++counter;
        }
        
        return const_iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,begin_ptr);
    }*/

    __forceinline__
    __host__ __device__ iterator_with_index<const_iterator> find(const key_type& k ) const
    {
        typename Hasher::result_type hash_value = m_hf( k );

        size_type current_index = hash_value % m_hashtbl_size;
        value_type *current_hash_bucket = m_hashtbl_values + current_index;

        value_type* current_ptr = 0;
        
        size_type counter = 0;

        while ( 0 == current_ptr ) {

            const key_type existing_key = current_hash_bucket->first;

            if( unused_key == existing_key || counter >= m_hashtbl_size ){
                current_ptr = m_hashtbl_values + m_hashtbl_size;
                break;
            }
            if ( k == existing_key ) {
                if( valid_marker[current_index] ){
                    current_ptr = current_hash_bucket;
                }
                else{
                    current_ptr = m_hashtbl_values + m_hashtbl_size;
                }
                break;
            }
            
            current_index = (current_index+1) % m_hashtbl_size;
            current_hash_bucket = m_hashtbl_values + current_index;
            ++counter;
        }

        iterator_with_index<const_iterator> return_result(const_iterator( m_hashtbl_values,m_hashtbl_values+m_hashtbl_size,current_ptr), current_index);
        
        return return_result;
    }


    template<typename aggregation_type,
             typename counter_type,
             class comparison_type = key_equal,
             typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ iterator get_insert(const key_type& k, 
                                   aggregation_type op,
                                   counter_type * value_counter,
                                   comparison_type keys_equal = key_equal(),
                                   bool precomputed_hash = false,
                                   hash_value_type precomputed_hash_value = 0)
    {
        const size_type hashtbl_size    = m_hashtbl_size;
        value_type* hashtbl_values      = m_hashtbl_values;

        hash_value_type hash_value{0};

        // If a precomputed hash value has been passed in, then use it to determine
        // the write location of the new key
        if(true == precomputed_hash)
        {
          hash_value = precomputed_hash_value;
        }
        // Otherwise, compute the hash value from the new key
        else
        {
          hash_value = m_hf(k);
        }

        size_type current_index         = hash_value % hashtbl_size;
        value_type *current_hash_bucket = &(hashtbl_values[current_index]);

        const key_type insert_key = k;
        
        bool insert_success = false;
        
        size_type counter = 0;
        while (false == insert_success) {
            // Situation %5: No slot: All slot in the hashtable is occupied by other key, both get and insert fail. Return empty iterator
            if (counter++ >= hashtbl_size) {
                return end();
            }

          key_type& existing_key = current_hash_bucket->first;
          volatile mapped_type& existing_value = current_hash_bucket->second;

          // Try and set the existing_key for the current hash bucket to insert_key
          const key_type old_key = atomicCAS( &existing_key, unused_key, insert_key);

          // If old_key == unused_key, the current hash bucket was empty
          // and existing_key was updated to insert_key by the atomicCAS. 
          // If old_key == insert_key, this key has already been inserted. 
          // In either case, perform the atomic aggregation of existing_value and insert_value
          // Because the hash table is initialized with the identity value of the aggregation
          // operation, it is safe to perform the operation when the existing_value still 
          // has its initial value
          // TODO: Use template specialization to make use of native atomic functions
          // TODO: How to handle data types less than 32 bits?

          // Situation #1: Empty slot: this key never exist in the table, ready to insert.
          if (keys_equal(unused_key, old_key)) {

            //update_existing_value(existing_value, x, op);
            existing_value = (mapped_type)(atomicAdd(value_counter, 1));
            break;

          } // Situation #2+#3: Target slot: This slot is the slot for this key
          else if(keys_equal(insert_key, old_key)){
              while(existing_value == m_unused_element){
                  // Situation #2: This slot is inserting by another CUDA thread and the value is not yet ready, just wait
              }
              // Situation #3: This slot is already ready, get successfully and return (iterator of) the value
              break;
          }
          // Situation 4: Wrong slot: This slot is occupied by other key, get fail, do nothing and linear probing to next slot.

          current_index = (current_index+1)%hashtbl_size;
          current_hash_bucket = &(hashtbl_values[current_index]);
        }
        
        return iterator( m_hashtbl_values,m_hashtbl_values+hashtbl_size, current_hash_bucket);
    }
    
    /*int assign_async( const concurrent_unordered_map& other, cudaStream_t stream = 0 )
    {
        m_collisions = other.m_collisions;
        if ( other.m_hashtbl_size <= m_hashtbl_capacity ) {
            m_hashtbl_size = other.m_hashtbl_size;
        } else {
            m_allocator.deallocate( m_hashtbl_values, m_hashtbl_capacity );
            m_hashtbl_capacity = other.m_hashtbl_size;
            m_hashtbl_size = other.m_hashtbl_size;
            
            m_hashtbl_values = m_allocator.allocate( m_hashtbl_capacity );
        }
        CUDA_RT_CALL( cudaMemcpyAsync( m_hashtbl_values, other.m_hashtbl_values, m_hashtbl_size*sizeof(value_type), cudaMemcpyDefault, stream ) );
        return 0;
    }*/
    
    void clear_async( cudaStream_t stream = 0 ) 
    {
        constexpr int block_size = 128;
        init_hashtbl<<<((m_hashtbl_size-1)/block_size)+1,block_size,0,stream>>>( m_hashtbl_values, valid_marker, m_hashtbl_size, unused_key, m_unused_element );
        if ( count_collisions )
            m_collisions = 0;
    }
    
    unsigned long long get_num_collisions() const
    {
        return m_collisions;
    }
    
    void print()
    {
        int32_t * h_valid_marker;
        CUDA_RT_CALL( cudaHostAlloc((void**) &h_valid_marker, m_hashtbl_capacity * sizeof(*h_valid_marker), cudaHostAllocPortable) );
        CUDA_RT_CALL( cudaMemcpy(h_valid_marker, (void*)valid_marker, m_hashtbl_capacity * sizeof(*h_valid_marker),  cudaMemcpyDeviceToHost) );
        for (size_type i = 0; i < m_hashtbl_size; ++i) 
        {
            std::cout<<i<<": "<<m_hashtbl_values[i].first<<","<<m_hashtbl_values[i].second<< ((h_valid_marker[i]) ? "Valid" : "Invalid") <<std::endl;
        }
        cudaFreeHost(h_valid_marker);
    }
    
    int prefetch( const int dev_id, cudaStream_t stream = 0 )
    {
        cudaPointerAttributes hashtbl_values_ptr_attributes;
        cudaError_t status = cudaPointerGetAttributes( &hashtbl_values_ptr_attributes, m_hashtbl_values );
        
#if CUDART_VERSION >= 10000
        if ( cudaSuccess == status && hashtbl_values_ptr_attributes.type == cudaMemoryTypeManaged )
#else
        if ( cudaSuccess == status && hashtbl_values_ptr_attributes.isManaged )
#endif
        {
            CUDA_RT_CALL( cudaMemPrefetchAsync(m_hashtbl_values, m_hashtbl_size*sizeof(value_type), dev_id, stream) );
        }
        CUDA_RT_CALL( cudaMemPrefetchAsync(this, sizeof(*this), dev_id, stream) );

        return 0;
    }
    /*
    template<class comparison_type = key_equal,
             typename hash_value_type = typename Hasher::result_type>
    __forceinline__
    __device__ const_iterator accum_(const value_type& x, 
                               comparison_type keys_equal = key_equal(),
                               bool precomputed_hash = false,
                               hash_value_type precomputed_hash_value = 0)
    {
        const key_type& dst_key = x.first;
        auto it = find(dst_key);


        if(it == end()){
            return it;
        }

        value_type* dst = it.getter();

        accum_existing_value_atomic(dst->second, x);

        return it;
    }*/

    __forceinline__
    __host__ __device__ void set_valid(size_type target_index, bool target_value){

        valid_marker[target_index] = target_value;

    }

    __forceinline__
    __host__ __device__ bool get_valid(size_type target_index) const{

        return valid_marker[target_index];

    }
    
private:
    const hasher            m_hf;
    const key_equal         m_equal;

    const mapped_type       m_unused_element;
    
    allocator_type              m_allocator;
    
    size_type   m_hashtbl_size;
    size_type   m_hashtbl_capacity;
    value_type* m_hashtbl_values;

    // Valid marker buffer
    volatile int32_t * valid_marker;
    // Bucket locks (Currently use uint32_t as lock, may use uint8_t in the future)
    //unsigned int* bucket_lock;
    
    unsigned long long m_collisions;

    // Bucket lock: atomically lock a bucket, if the bucket is already locked, block until grab the lock(i.e. spining lock)
    /*__forceinline__
    __device__ void lock_bucket(size_type lock_index){
        // Memory fence to ensure memory consistency
        __threadfence();
        while( atomicCAS(bucket_lock + lock_index, 0, 1) ){

        }
    }*/

    // Bucket unlock: atomically unlock a bucket, this function must be called by the CUDA thread already own the lock.
    /*__forceinline__
    __device__ void unlock_bucket(size_type lock_index){
        // Memory fence to ensure memory consistency
        __threadfence();
        atomicCAS(bucket_lock + lock_index, 1, 0);
    }*/
};

#endif //CONCURRENT_UNORDERED_MAP_CUH
