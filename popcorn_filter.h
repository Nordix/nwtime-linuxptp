/**
 * @file popcorn_filter.h
 * @brief Implements popcorn spike filter for offset measurements.
 * @note Copyright (C) 2026 Muhammad Adil Ghaffar <muhammad.adil.ghaffar@est.tech>
 * @note SPDX-License-Identifier: GPL-2.0+
 */
#ifndef HAVE_POPCORN_FILTER_H
#define HAVE_POPCORN_FILTER_H

#include <time.h>

#define OFFSET_WINDOW_SZ 8

struct clock;

struct popcorn_filter {
	double last_offset;
	struct timespec last_offset_ts;
	double offset_jitter;
	double offset_buffer[OFFSET_WINDOW_SZ];
	int offset_hist_cnt;
	int offset_hist_idx;
};

/**
 * Create a new instance of a popcorn filter.
 * @return A pointer to a new popcorn filter on success, NULL otherwise.
 */
struct popcorn_filter *popcorn_filter_create(void);

/**
 * Destroy an instance of a popcorn filter.
 * @param filter Pointer to a filter obtained via @ref popcorn_filter_create().
 */
void popcorn_filter_destroy(struct popcorn_filter *filter);

/**
 * Calculate offset jitter.
 * @param filter Pointer to a filter obtained via @ref popcorn_filter_create().
 * @return The offset jitter value.
 */
double popcorn_offset_jitter(struct popcorn_filter *filter);

/**
 * Process offset sample through popcorn spike filter.
 * @param filter Pointer to a filter obtained via @ref popcorn_filter_create().
 * @param c Pointer to the clock structure.
 * @param offset Current offset value in nanoseconds.
 * @return 0 if sample accepted, 1 if spike detected and suppressed.
 */
int popcorn_filter_sample(struct popcorn_filter *filter, struct clock *c,
			  double offset);

#endif
