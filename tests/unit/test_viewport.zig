const std = @import("std");
const testing = std.testing;
const viewport = @import("viewport");

test "screenToComplex maps center pixel to center coordinates" {
	const result = viewport.screenToComplex(.{
		.col = 40,
		.row = 12,
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 80,
		.height = 24,
		.aspect_ratio = 0.5,
	});
	try testing.expectApproxEqAbs(@as(f64, -0.5), @as(f64, @floatCast(result.re)), 0.1);
	try testing.expectApproxEqAbs(@as(f64, 0.0), @as(f64, @floatCast(result.im)), 0.1);
}

test "screenToComplex at higher zoom narrows visible range" {
	const zoom1 = viewport.screenToComplex(.{
		.col = 0,
		.row = 0,
		.center_re = 0.0,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 80,
		.height = 24,
		.aspect_ratio = 0.5,
	});
	const zoom2 = viewport.screenToComplex(.{
		.col = 0,
		.row = 0,
		.center_re = 0.0,
		.center_im = 0.0,
		.zoom = 2.0,
		.width = 80,
		.height = 24,
		.aspect_ratio = 0.5,
	});
	const dist1_f64: f64 = @floatCast(zoom1.re * zoom1.re + zoom1.im * zoom1.im);
	const dist2_f64: f64 = @floatCast(zoom2.re * zoom2.re + zoom2.im * zoom2.im);
	try testing.expect(dist2_f64 < dist1_f64);
}

test "zoomAt recenters on the clicked point" {
	const state = viewport.ViewState{
		.center_re = 0.0,
		.center_im = 0.0,
		.zoom = 1.0,
		.base_iter = 256,
		.max_iter = 256,
	};
	const new_state = viewport.zoomAt(state, 2.0, 60, 12, 80, 24, 0.5);
	try testing.expect(new_state.center_re != 0.0);
	try testing.expectApproxEqAbs(@as(f64, 2.0), @as(f64, @floatCast(new_state.zoom)), 0.001);
}

test "zoomAt at center pixel preserves center" {
	const state = viewport.ViewState{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.base_iter = 256,
		.max_iter = 256,
	};
	const new_state = viewport.zoomAt(state, 2.0, 40, 12, 80, 24, 0.5);
	try testing.expectApproxEqAbs(@as(f64, -0.5), @as(f64, @floatCast(new_state.center_re)), 0.001);
	try testing.expectApproxEqAbs(@as(f64, 0.0), @as(f64, @floatCast(new_state.center_im)), 0.001);
}

test "pan shifts center by 10% of visible range" {
	const state = viewport.ViewState{
		.center_re = 0.0,
		.center_im = 0.0,
		.zoom = 1.0,
		.base_iter = 256,
		.max_iter = 256,
	};
	const right = viewport.pan(state, .right, 80, 24, 0.5);
	try testing.expect(right.center_re > 0.0);
	try testing.expectApproxEqAbs(@as(f64, 0.4), @as(f64, @floatCast(right.center_re)), 0.001);
}

test "adaptiveMaxIter increases with zoom depth" {
	const iter1 = viewport.adaptiveMaxIter(1.0, 256);
	const iter10 = viewport.adaptiveMaxIter(1000.0, 256);
	const iter20 = viewport.adaptiveMaxIter(1_000_000.0, 256);
	try testing.expect(iter10 > iter1);
	try testing.expect(iter20 > iter10);
}

test "adaptiveMaxIter at zoom=1 returns base" {
	const result = viewport.adaptiveMaxIter(1.0, 256);
	try testing.expectEqual(@as(u32, 256), result);
}
