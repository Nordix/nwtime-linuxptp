/**
 * @file popcorn_filter.c
 * @brief Implements popcorn spike filter for offset filtering
 * @note Copyright (C) 2026 Muhammad Adil Ghaffar <muhammad.adil.ghaffar@est.tech>
 * @note SPDX-License-Identifier: GPL-2.0+
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "popcorn_filter.h"
#include "clock.h"
#include "port.h"
#include "tmv.h"

struct popcorn_filter *popcorn_filter_create(void)
{
	struct popcorn_filter *filter;
	filter = calloc(1, sizeof(*filter));
	if (!filter) {
		return NULL;
	}

	memset(filter->offset_buffer, 0, sizeof(filter->offset_buffer));
	filter->offset_hist_cnt = 0;
	filter->offset_hist_idx = 0;
	filter->offset_jitter = 0;
	filter->last_offset = 0;
	filter->last_offset_ts = (struct timespec){0};

	return filter;
}

void popcorn_filter_destroy(struct popcorn_filter *filter)
{
	if (filter) {
		free(filter);
	}
}

double popcorn_offset_jitter(struct popcorn_filter *filter)
{
	int i;
	double mean = 0.0, var = 0.0;

	for (i = 0; i < filter->offset_hist_cnt; i++)
		mean += filter->offset_buffer[i];
	mean /= filter->offset_hist_cnt;

	for (i = 0; i < filter->offset_hist_cnt; i++) {
		double d = filter->offset_buffer[i] - mean;
		var += d * d;
	}

	return sqrt(var / filter->offset_hist_cnt);
}

int popcorn_filter_sample(struct popcorn_filter *filter, struct clock *c,
			  double offset)
{
	struct timespec now;
	struct port *slave_port;
	int log_sync_interval = 0;
	int skip_offset = 0;

	clock_gettime(clock_clkid(c), &now);

	slave_port = clock_best_port(c);
	if (slave_port) {
		log_sync_interval = port_log_sync_interval(slave_port);
	}

	/* Check for spike if we have enough history and servo is locked */
	if (filter->offset_hist_cnt >= 2 && clock_servo_state(c) == SERVO_LOCKED) {
		double delta = fabs(offset - filter->last_offset);
		double jitter = filter->offset_jitter;

		double dt = tmv_to_nanoseconds(tmv_sub(
			timespec_to_tmv(now),
			timespec_to_tmv(filter->last_offset_ts)));
		double sync_interval = pow(2.0, log_sync_interval);

		if (delta > clock_popcorn_spike_gate(c) * jitter &&
		    dt < 2.0 * sync_interval) {
			skip_offset = 1;
		}
	}

	if (skip_offset) {
		return 1; /* Spike detected, sample rejected */
	}

	/* Update offset history with accepted sample */
	filter->offset_buffer[filter->offset_hist_idx] = offset;
	filter->offset_hist_idx = (filter->offset_hist_idx + 1) % OFFSET_WINDOW_SZ;

	if (filter->offset_hist_cnt < OFFSET_WINDOW_SZ)
		filter->offset_hist_cnt++;

	if (filter->offset_hist_cnt >= 2) {
		filter->offset_jitter = popcorn_offset_jitter(filter);
	}

	filter->last_offset = offset;
	filter->last_offset_ts = now;
	return 0; /* Sample accepted */
}
