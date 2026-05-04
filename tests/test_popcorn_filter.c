/**
 * @file test_popcorn_filter.c
 * @brief Unit tests for the popcorn spike filter.
 *
 * These tests exercise the popcorn filter in isolation by providing stub
 * implementations of the clock and port functions it depends on. This
 * allows verifying the filter logic without running ptp4l or requiring
 * PTP hardware.
 *
 * Build and run:
 *   make test                                  # build + run
 *   make test_popcorn_filter && ./test_popcorn_filter   # manual
 *
 * The exit code is 0 when all tests pass and 1 on any failure.
 * Individual failures are printed to stderr with file/line information.
 *
 * Test overview:
 *   test_create_destroy              - Filter allocation and initial state.
 *   test_jitter_calculation          - Offset jitter (stddev) math.
 *   test_accepts_samples_when_unlocked - No filtering before servo locks.
 *   test_accepts_normal_samples_when_locked - Small offsets pass through.
 *   test_rejects_spike_when_locked   - Large spike rejected while locked.
 *   test_accepts_after_long_gap      - Spike accepted when dt >> sync interval.
 *   test_buffer_wraps_correctly      - Ring buffer index wrap-around.
 */
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "popcorn_filter.h"
#include "servo.h"

/*
 * Stubs for clock/port functions used by popcorn_filter_sample().
 *
 * The real implementations live in clock.c and port.c and pull in most of
 * the linuxptp object graph. These minimal stubs supply only what the
 * popcorn filter needs: the clock ID, servo state, spike gate multiplier,
 * the best port, and the port's sync interval.
 *
 * Test code controls behaviour by setting the static stub_* variables
 * before calling popcorn_filter_sample().
 */
static enum servo_state stub_servo_state = SERVO_UNLOCKED;
static int stub_spike_gate = 3;
static int stub_log_sync_interval = 0;

struct clock {
	clockid_t clkid;
	enum servo_state servo_state;
	int popcorn_spike_gate;
};

struct port {
	int log_sync_interval;
};

/* Keep a static port and clock for the stubs */
static struct clock test_clock;
static struct port test_port;

clockid_t clock_clkid(struct clock *c)
{
	return c->clkid;
}

enum servo_state clock_servo_state(struct clock *c)
{
	return stub_servo_state;
}

int clock_popcorn_spike_gate(struct clock *c)
{
	return stub_spike_gate;
}

struct port *clock_best_port(struct clock *c)
{
	return &test_port;
}

int port_log_sync_interval(struct port *p)
{
	return stub_log_sync_interval;
}

/* ---- Test helpers ---- */

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT_INT_EQ(expected, actual, msg) do { \
	tests_run++; \
	if ((expected) == (actual)) { \
		tests_passed++; \
	} else { \
		fprintf(stderr, "FAIL [%s:%d] %s: expected %d, got %d\n", \
			__FILE__, __LINE__, msg, (expected), (actual)); \
	} \
} while (0)

#define ASSERT_DBL_NEAR(expected, actual, tol, msg) do { \
	tests_run++; \
	if (fabs((expected) - (actual)) < (tol)) { \
		tests_passed++; \
	} else { \
		fprintf(stderr, "FAIL [%s:%d] %s: expected %.6f, got %.6f\n", \
			__FILE__, __LINE__, msg, (expected), (actual)); \
	} \
} while (0)

/* ---- Tests ---- */

/*
 * Verify that popcorn_filter_create() returns a valid, zero-initialised
 * filter and that popcorn_filter_destroy() frees it without error.
 */
static void test_create_destroy(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	assert(f != NULL);
	ASSERT_INT_EQ(0, f->offset_hist_cnt, "initial hist count is 0");
	ASSERT_INT_EQ(0, f->offset_hist_idx, "initial hist idx is 0");
	ASSERT_DBL_NEAR(0.0, f->offset_jitter, 1e-9, "initial jitter is 0");
	popcorn_filter_destroy(f);
}

/*
 * Verify popcorn_offset_jitter() computes the population standard
 * deviation of the offset buffer.  Uses the known data set [10, 20, 30, 40]
 * whose stddev is sqrt(125) ≈ 11.180.
 */
static void test_jitter_calculation(void)
{
	struct popcorn_filter *f = popcorn_filter_create();

	/* Fill buffer with known values: [10, 20, 30, 40] */
	f->offset_buffer[0] = 10.0;
	f->offset_buffer[1] = 20.0;
	f->offset_buffer[2] = 30.0;
	f->offset_buffer[3] = 40.0;
	f->offset_hist_cnt = 4;

	double jitter = popcorn_offset_jitter(f);
	/* mean = 25, var = ((15^2 + 5^2 + 5^2 + 15^2) / 4) = 125 */
	/* stddev = sqrt(125) ≈ 11.180 */
	ASSERT_DBL_NEAR(sqrt(125.0), jitter, 0.001, "jitter for [10,20,30,40]");

	popcorn_filter_destroy(f);
}

/*
 * When the servo has not yet locked (SERVO_UNLOCKED), the filter must
 * accept every sample regardless of how large the offset jump is.
 * This ensures PTP can converge freely during initial synchronisation.
 */
static void test_accepts_samples_when_unlocked(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	stub_servo_state = SERVO_UNLOCKED;
	test_clock.clkid = CLOCK_REALTIME;

	/* Even with wildly varying offsets, samples should be accepted
	 * because servo is not locked. */
	int rc;
	rc = popcorn_filter_sample(f, &test_clock, 100.0);
	ASSERT_INT_EQ(0, rc, "accept first sample when unlocked");

	rc = popcorn_filter_sample(f, &test_clock, 200.0);
	ASSERT_INT_EQ(0, rc, "accept second sample when unlocked");

	rc = popcorn_filter_sample(f, &test_clock, 99999.0);
	ASSERT_INT_EQ(0, rc, "accept spike when unlocked");

	popcorn_filter_destroy(f);
}

/*
 * Once the servo is locked, small (within-jitter) offset changes should
 * still be accepted.  This test feeds monotonically increasing samples
 * that differ by only 1 ns — well below the spike_gate * jitter threshold.
 */
static void test_accepts_normal_samples_when_locked(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	stub_servo_state = SERVO_LOCKED;
	stub_spike_gate = 3;
	stub_log_sync_interval = 0; /* 1 second interval */
	test_clock.clkid = CLOCK_REALTIME;

	/* Feed stable samples to build history */
	int rc;
	rc = popcorn_filter_sample(f, &test_clock, 100.0);
	ASSERT_INT_EQ(0, rc, "accept 1st sample (building history)");

	rc = popcorn_filter_sample(f, &test_clock, 101.0);
	ASSERT_INT_EQ(0, rc, "accept 2nd sample (building history)");

	rc = popcorn_filter_sample(f, &test_clock, 102.0);
	ASSERT_INT_EQ(0, rc, "accept 3rd sample (normal, locked)");

	rc = popcorn_filter_sample(f, &test_clock, 103.0);
	ASSERT_INT_EQ(0, rc, "accept 4th sample (normal, locked)");

	popcorn_filter_destroy(f);
}

/*
 * Core spike-rejection test.  With a full history of stable offsets
 * (jitter ≈ 0.5 ns), a sudden jump to 10000 ns far exceeds
 * spike_gate(3) * jitter and arrives within 2× the sync interval,
 * so the filter must reject it (return 1).
 */
static void test_rejects_spike_when_locked(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	stub_servo_state = SERVO_LOCKED;
	stub_spike_gate = 3;
	stub_log_sync_interval = 0; /* 1 second sync interval */
	test_clock.clkid = CLOCK_REALTIME;

	/* Manually fill in stable history to simulate a locked servo */
	int i;
	for (i = 0; i < OFFSET_WINDOW_SZ; i++) {
		f->offset_buffer[i] = 100.0 + (i % 2); /* 100, 101, 100, 101, ... */
	}
	f->offset_hist_cnt = OFFSET_WINDOW_SZ;
	f->offset_hist_idx = 0;
	f->offset_jitter = popcorn_offset_jitter(f);
	f->last_offset = 100.0;

	/* Set last_offset_ts to just now so dt < 2*sync_interval */
	clock_gettime(CLOCK_REALTIME, &f->last_offset_ts);

	printf("  jitter = %.3f ns\n", f->offset_jitter);

	/* A huge spike should be rejected: delta=9900 >> 3*jitter */
	int rc = popcorn_filter_sample(f, &test_clock, 10000.0);
	ASSERT_INT_EQ(1, rc, "reject large spike when locked");

	popcorn_filter_destroy(f);
}

/*
 * If a long time has elapsed since the last accepted sample (dt >> 2×
 * sync_interval), the spike could be a legitimate clock step rather than
 * noise.  The filter must accept it so PTP can re-converge.
 */
static void test_accepts_after_long_gap(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	stub_servo_state = SERVO_LOCKED;
	stub_spike_gate = 3;
	stub_log_sync_interval = 0; /* 1 second sync interval */
	test_clock.clkid = CLOCK_REALTIME;

	/* Fill stable history */
	int i;
	for (i = 0; i < OFFSET_WINDOW_SZ; i++) {
		f->offset_buffer[i] = 100.0;
	}
	f->offset_hist_cnt = OFFSET_WINDOW_SZ;
	f->offset_hist_idx = 0;
	f->offset_jitter = popcorn_offset_jitter(f);
	f->last_offset = 100.0;

	/* Set last_offset_ts to 10 seconds ago (>> 2*1s sync interval) */
	clock_gettime(CLOCK_REALTIME, &f->last_offset_ts);
	f->last_offset_ts.tv_sec -= 10;

	/* Even a large offset change should be accepted because dt > 2*sync_interval */
	int rc = popcorn_filter_sample(f, &test_clock, 10000.0);
	ASSERT_INT_EQ(0, rc, "accept spike after long gap (dt > 2*sync_interval)");

	popcorn_filter_destroy(f);
}

/*
 * The offset history is stored in a fixed-size ring buffer of
 * OFFSET_WINDOW_SZ entries.  After inserting more samples than the
 * buffer can hold, verify that the index wraps around correctly and
 * the count stays capped at OFFSET_WINDOW_SZ.
 */
static void test_buffer_wraps_correctly(void)
{
	struct popcorn_filter *f = popcorn_filter_create();
	stub_servo_state = SERVO_UNLOCKED;
	test_clock.clkid = CLOCK_REALTIME;

	/* Feed more than OFFSET_WINDOW_SZ samples */
	int i;
	for (i = 0; i < OFFSET_WINDOW_SZ + 4; i++) {
		popcorn_filter_sample(f, &test_clock, (double)(i * 10));
	}

	ASSERT_INT_EQ(OFFSET_WINDOW_SZ, f->offset_hist_cnt,
		      "hist count caps at window size");
	ASSERT_INT_EQ(4, f->offset_hist_idx,
		      "hist idx wraps correctly");

	/* Verify the buffer contains the last OFFSET_WINDOW_SZ values */
	/* Index 4 should be the oldest remaining = sample 4 (value 40) */
	ASSERT_DBL_NEAR(40.0, f->offset_buffer[4], 0.001,
			"oldest sample in wrapped buffer");

	popcorn_filter_destroy(f);
}

int main(void)
{
	printf("=== Popcorn Filter Unit Tests ===\n\n");

	printf("test_create_destroy...\n");
	test_create_destroy();

	printf("test_jitter_calculation...\n");
	test_jitter_calculation();

	printf("test_accepts_samples_when_unlocked...\n");
	test_accepts_samples_when_unlocked();

	printf("test_accepts_normal_samples_when_locked...\n");
	test_accepts_normal_samples_when_locked();

	printf("test_rejects_spike_when_locked...\n");
	test_rejects_spike_when_locked();

	printf("test_accepts_after_long_gap...\n");
	test_accepts_after_long_gap();

	printf("test_buffer_wraps_correctly...\n");
	test_buffer_wraps_correctly();

	printf("\n=== Results: %d/%d passed ===\n", tests_passed, tests_run);
	return (tests_passed == tests_run) ? 0 : 1;
}
