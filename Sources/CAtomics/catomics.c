// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

#include "catomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct catomic_u32 { _Atomic uint32_t value; };
struct catomic_u64 { _Atomic uint64_t value; };
struct catomic_bool { _Atomic bool value; };

catomic_u32 *catomic_u32_create(uint32_t value) {
    catomic_u32 *atomic = malloc(sizeof *atomic);
    if (atomic) atomic_init(&atomic->value, value);
    return atomic;
}
void catomic_u32_destroy(catomic_u32 *atomic) { free(atomic); }
uint32_t catomic_u32_load(catomic_u32 *atomic) {
    return atomic_load_explicit(&atomic->value, memory_order_relaxed);
}
void catomic_u32_store(catomic_u32 *atomic, uint32_t value) {
    atomic_store_explicit(&atomic->value, value, memory_order_relaxed);
}

catomic_u64 *catomic_u64_create(uint64_t value) {
    catomic_u64 *atomic = malloc(sizeof *atomic);
    if (atomic) atomic_init(&atomic->value, value);
    return atomic;
}
void catomic_u64_destroy(catomic_u64 *atomic) { free(atomic); }
uint64_t catomic_u64_load(catomic_u64 *atomic) {
    return atomic_load_explicit(&atomic->value, memory_order_relaxed);
}
void catomic_u64_add(catomic_u64 *atomic, uint64_t value) {
    atomic_fetch_add_explicit(&atomic->value, value, memory_order_relaxed);
}

catomic_bool *catomic_bool_create(bool value) {
    catomic_bool *atomic = malloc(sizeof *atomic);
    if (atomic) atomic_init(&atomic->value, value);
    return atomic;
}
void catomic_bool_destroy(catomic_bool *atomic) { free(atomic); }
bool catomic_bool_exchange(catomic_bool *atomic, bool value) {
    return atomic_exchange_explicit(&atomic->value, value, memory_order_relaxed);
}
