// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

// Relaxed atomics for the audio render thread on every supported macOS
// (Swift's Synchronization.Atomic needs macOS 15). Lock-free, never block.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct catomic_u32 catomic_u32;
typedef struct catomic_u64 catomic_u64;
typedef struct catomic_bool catomic_bool;

catomic_u32 *catomic_u32_create(uint32_t value);
void catomic_u32_destroy(catomic_u32 *atomic);
uint32_t catomic_u32_load(catomic_u32 *atomic);
void catomic_u32_store(catomic_u32 *atomic, uint32_t value);

catomic_u64 *catomic_u64_create(uint64_t value);
void catomic_u64_destroy(catomic_u64 *atomic);
uint64_t catomic_u64_load(catomic_u64 *atomic);
void catomic_u64_add(catomic_u64 *atomic, uint64_t value);

catomic_bool *catomic_bool_create(bool value);
void catomic_bool_destroy(catomic_bool *atomic);
/// Stores `value` and returns the previous one.
bool catomic_bool_exchange(catomic_bool *atomic, bool value);
