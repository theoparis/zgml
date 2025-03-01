const std = @import("std");

const tensorlib = @import("./tensor.zig");
const Tensor = tensorlib.Tensor;
const assert = std.debug.assert;
const testing = std.testing;
const Alloc = std.mem.Allocator;
const tac = std.testing.allocator;

pub fn ComputeGraph(comptime T: type) type {
    return struct {
        const Self = @This();

        built_forward: bool = false,
        built_backward: bool = false,

        nodes: std.ArrayList(*Tensor(T)),
        grads: std.ArrayList(?*Tensor(T)),
        leaves: std.ArrayList(*Tensor(T)),

        scratch: std.ArrayList(*Tensor(T)),

        /// Set up resources for compute graph.
        /// Must call `buildForward` (then optionally `buildBackward`) to be able to do computation.
        pub fn init(alloc: Alloc) Self {
            var graph: Self = .{
                .nodes = std.ArrayList(*Tensor(T)).init(alloc),
                .grads = std.ArrayList(?*Tensor(T)).init(alloc),
                .leaves = std.ArrayList(*Tensor(T)).init(alloc),
                .scratch = std.ArrayList(*Tensor(T)).init(alloc),
            };
            return graph;
        }
        /// Clean up all the resources for this compute graph
        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |t| {
                t.deinit();
            }
            self.nodes.deinit();
            if (!self.built_backward) {
                for (self.grads.items) |grad_o| {
                    if (grad_o) |grad| grad.deinit();
                }
            }
            self.grads.deinit();
            for (self.leaves.items) |t| {
                t.deinit();
            }
            self.leaves.deinit();
            // for (self.scratch.items) |t| {
            //     t.deinit();
            // }
            self.scratch.deinit();
        }

        /// Build a graph where the provided tensor is the final output node
        pub fn buildForward(self: *Self, tensor: *Tensor(T)) Alloc.Error!void {
            const n_before = self.nodes.items.len;
            try self.addParentsThenSelf(tensor);
            // tensor should be last node
            const n_change = self.nodes.items.len - n_before;
            if (n_change > 0) assert(self.nodes.items[self.nodes.items.len - 1] == tensor);
            self.built_forward = true;
        }
        /// Build a backward graph
        pub fn buildBackward(self: *Self, keep: bool) Alloc.Error!void {
            assert(self.nodes.items.len > 0);
            // if we are keeping the gradient graph,
            // we have to detach the gradient nodes from the original graph
            // if (keep) {
            //     for (self.nodes.items, self.grads.items) |node, grad| {
            //         if (node.grad) |node_grad| {
            //             node.grad = try node.copyTensorShape(alloc);
            //             // if we are detaching the node, the user now owns the memory
            //             // so we don't need to free it
            //             grad.?.* = node_grad.*;
            //         }
            //     }
            // }
            const nodes_len = self.nodes.items.len;
            for (0..nodes_len) |j| {
                const i = nodes_len - j - 1;
                const node = self.nodes.items[i];

                // because we detached the grad nodes from the original graph, we can afford inplace operations
                if (node.grad != null) {
                    try node.backward(&self.scratch, keep);
                }
            }
            for (0..nodes_len) |j| {
                const i = nodes_len - j - 1;
                const node = self.nodes.items[i];
                if (node.is_param) {
                    assert(node.grad != null);
                    try self.buildForward(node.grad.?);
                }
            }
            self.built_backward = true;
            self.resetGrads();
        }
        fn addParentsThenSelf(self: *Self, tensor: *Tensor(T)) Alloc.Error!void {
            // std.debug.print("Visiting {*}\n", .{tensor});
            // check if already visited
            for (self.nodes.items) |node| {
                if (tensor == node) {
                    return;
                }
            }
            for (self.leaves.items) |node| {
                if (tensor == node) {
                    return;
                }
            }
            // visit parents
            if (tensor.src0) |ts0| try self.addParentsThenSelf(ts0);
            if (tensor.src1) |ts1| try self.addParentsThenSelf(ts1);
            for (tensor.opt) |t_o| {
                if (t_o) |t| {
                    try self.addParentsThenSelf(t);
                }
            }
            if (tensor.op == .none and tensor.grad == null) {
                // is leaf
                // std.debug.print("Appending {*} to leaves\n", .{tensor});
                try self.leaves.append(tensor);
            } else {
                // std.debug.print("Appending {*} to nodes\n", .{tensor});
                try self.nodes.append(tensor);
                try self.grads.append(tensor.grad);
            }
        }
        pub fn toGraphViz(self: *const Self) Alloc.Error!std.ArrayList(u8) {
            var str = std.ArrayList(u8).init(self.nodes.allocator);
            const writer = str.writer();
            try writer.print("digraph G {{\n", .{});
            for (self.nodes.items) |node| {
                // try writer.print("  \"{*}\" [shape=\"none\",label=<<table><tr><td>{s}</td></tr><tr><td>{any}</td></tr></table>>];\n", .{ node, node.op.symbol(), node.data });
                try writer.print("  \"{*}\" [shape=\"none\",label=<<table>", .{node});
                if (node.op == .none) {
                    try writer.print("<tr><td>{any}</td></tr>", .{node.data});
                } else {
                    try writer.print("<tr><td>{s}</td></tr>", .{node.op.symbol()});
                }
                if (node.name) |name| {
                    try writer.print("<tr><td>{s}</td></tr>", .{name});
                }
                try writer.print("<tr><td>{any}</td></tr>", .{node.ne});
                try writer.print("</table>>];\n", .{});
                if (node.src0) |src0| {
                    try writer.print("  \"{*}\" -> \"{*}\";\n", .{ src0, node });
                }
                if (node.src1) |src1| {
                    try writer.print("  \"{*}\" -> \"{*}\";\n", .{ src1, node });
                }
                if (node.grad) |grad| {
                    try writer.print("  \"{*}\" -> \"{*}\" [style=dashed];\n", .{ node, grad });
                }
            }
            for (self.leaves.items) |leaf| {
                try writer.print("  \"{*}\" [style=filled fillcolor=green label=\"{any}\"];\n", .{ leaf, leaf.data });
            }
            for (self.scratch.items) |item| {
                try writer.print("  \"{*}\" [style=filled fillcolor=gray label=\"{any}\"];\n", .{ item, item.data });
            }
            try writer.print("}}\n", .{});
            return str;
        }

        pub fn resetGrads(self: *Self) void {
            for (self.grads.items) |grad_o| {
                if (grad_o) |grad| {
                    _ = grad.setAllScalar(0);
                }
            }
        }

        pub fn compute(self: *const Self) void {
            for (self.nodes.items) |node| {
                node.compute();
            }
        }
    };
}

test "ref all decls" {
    _ = testing.refAllDeclsRecursive(ComputeGraph(f32));
}

test "tensor compute graph - matmul" {
    const t1 = try Tensor(f32).init(tac, &.{ 2, 3 });
    t1.setData(&[_]f32{
        1, 2,
        3, 4,
        5, 6,
    });
    try t1.setParam();

    const t2 = try Tensor(f32).init(tac, &.{ 3, 2 });
    t2.setData(&[_]f32{
        1, 2, 3,
        4, 5, 6,
    });
    // try t2.setParam(); // TODO: fix memleak

    const dst = try t1.matMul(false, t2, false);
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(dst);
    try g.buildBackward(false);

    _ = dst.grad.?.setAllScalar(1);
    g.compute();
    {
        const expected = [_]f32{
            9,  12, 15,
            19, 26, 33,
            29, 40, 51,
        };
        try testing.expectEqualSlices(f32, &expected, dst.data);
    }
    {
        const expected = [_]f32{
            6, 15,
            6, 15,
            6, 15,
        };
        try testing.expectEqualSlices(f32, &expected, t1.grad.?.data);
    }
    // {
    //     const expected = [_]f32{
    //         9,  9,  9,
    //         12, 12, 12,
    //     };
    //     try testing.expectEqualSlices(f32, &expected, t2.grad.?.data);
    // }
}

test "build compute graph - forward mul" {
    const t0 = try Tensor(f32).init(tac, &.{1});
    t0.data[0] = 5;
    const t1 = try Tensor(f32).init(tac, &.{1});
    t1.data[0] = 6;
    const out = try t0.mul(t1);
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    try g.buildBackward(false);
    g.compute();
    {
        const expected = [_]f32{30};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
}

test "build compute graph - forward matMul" {
    const t1 = try Tensor(f32).init(tac, &.{ 2, 3 });
    t1.setData(&[_]f32{
        1, 2,
        3, 4,
        5, 6,
    });
    const intermed = try t1.matMul(true, t1, false);
    const out = try intermed.matMul(false, t1, true);
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    g.compute();
    // {
    //     const dotviz = try g.toGraphViz();
    //     defer dotviz.deinit();
    //     std.debug.print("{s}\n", .{dotviz.items});
    // }
    {
        const expected = [_]f32{
            35, 44,
            44, 56,
        };
        try testing.expectEqualSlices(f32, &expected, intermed.data);
    }
    {
        const expected = [_]f32{
            123, 281, 439, //
            156, 356, 556,
        };
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
}

test "build compute graph - forward mul & add" {
    const x = try Tensor(f32).initScalar(tac, 3);
    const w = try Tensor(f32).initScalar(tac, 2);
    try w.setParam();
    const b = try Tensor(f32).initScalar(tac, 5);
    try b.setParam();
    const intermed = try w.mul(x);
    const out = try intermed.add(b);
    // w*x + b
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    g.compute();
    // {
    //     const dotviz = try g.toGraphViz();
    //     defer dotviz.deinit();
    //     std.debug.print("{s}\n", .{dotviz.items});
    // }
    {
        const expected = [_]f32{11};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
}

test "build compute graph - backward" {
    const x = try Tensor(f32).initScalar(tac, 3);
    const w = try Tensor(f32).initScalar(tac, 2);
    try w.setParam();
    const b = try Tensor(f32).initScalar(tac, 5);
    try b.setParam();
    const intermed = try w.mul(x);
    const out = try intermed.add(b);
    // w*x + b
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    try g.buildBackward(false);
    _ = out.grad.?.setAllScalar(1);
    g.compute();
    // {
    //     const dotviz = try g.toGraphViz();
    //     defer dotviz.deinit();
    //     std.debug.print("{s}\n", .{dotviz.items});
    // }
    {
        const expected = [_]f32{11};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
    {
        const expected = [_]f32{3};
        try testing.expectEqualSlices(f32, &expected, w.grad.?.data);
    }
    {
        const expected = [_]f32{1};
        try testing.expectEqualSlices(f32, &expected, b.grad.?.data);
    }
}

fn testSqrFunc(x: *Tensor(f32)) Alloc.Error!*Tensor(f32) {
    return try x.sqr();
}

test "build compute graph - backward - testSqrFunc" {
    const x = try Tensor(f32).initScalar(tac, 3);
    try x.setParam();
    const out = try testSqrFunc(x);
    // x^2
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    try g.buildBackward(true);

    _ = out.grad.?.setAllScalar(1);
    g.compute();
    {
        const expected = [_]f32{9};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
    {
        const expected = [_]f32{6};
        try testing.expectEqualSlices(f32, &expected, x.grad.?.data);
    }
    const iters = 10;
    for (0..iters) |_| {
        g.compute();
    }
    // {
    //     const dotviz = try g.toGraphViz();
    //     defer dotviz.deinit();
    //     std.debug.print("{s}\n", .{dotviz.items});
    // }
    {
        const expected = [_]f32{9};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
    // accumulated gradient
    {
        const expected = [_]f32{6 * (iters + 1)};
        try testing.expectEqualSlices(f32, &expected, x.grad.?.data);
    }
}

fn testSqrSumFunc(x: *Tensor(f32)) Alloc.Error!*Tensor(f32) {
    return try (try x.sqr()).sum();
}

test "build compute graph - backward - testSqrSumFunc" {
    const x = try Tensor(f32).init(tac, &.{3});
    const data = [_]f32{ 3, 4, 10 };
    x.setData(&data);
    try x.setParam();
    const out = try testSqrSumFunc(x);
    // x^2
    var g = ComputeGraph(f32).init(tac);
    defer g.deinit();
    try g.buildForward(out);
    try g.buildBackward(true);

    _ = out.grad.?.setAllScalar(1);
    g.compute();
    {
        const expected = [_]f32{125};
        try testing.expectEqualSlices(f32, &expected, out.data);
    }
    {
        // 2 * xt
        const expected = [_]f32{ 6, 8, 20 };
        try testing.expectEqualSlices(f32, &expected, x.grad.?.data);
    }
}

test "time speed equation test" {
    {
        const time = try Tensor(f32).initArange(tac, &.{20}, 0, 20);

        const c0 = try Tensor(f32).initScalar(tac, 0.75);
        const c1 = try Tensor(f32).initScalar(tac, 9.5);
        const c2 = try Tensor(f32).initScalar(tac, 1);

        const inner = try time.sub(try c1.repeatLike(time));
        const inner2 = try inner.sqr();
        const inner3 = try inner2.mul(try c0.repeatLike(inner2));
        const speed = try inner3.add(try c2.repeatLike(inner3));

        var g = ComputeGraph(f32).init(tac);
        defer g.deinit();
        try g.buildForward(speed);
        g.compute();

        try testing.expectEqual(@as(usize, 20), time.nElems());
        for (time.data, speed.data) |t, s| {
            const t1 = t - 9.5;
            try testing.expectEqual(0.75 * (t1 * t1) + 1, s);
        }
    }
}

fn mseFunc(x: *Tensor(f32), y: *Tensor(f32)) Alloc.Error!*Tensor(f32) {
    const diff = try x.sub(y);
    const diff2 = try diff.sqr();
    return try diff2.sum(); // TODO: switch to mean
}

const QuadraticModel = struct {
    const Self = @This();

    params: [3]*Tensor(f32),
    g: ComputeGraph(f32),
    out: *Tensor(f32),
    loss: *Tensor(f32),

    fn build(alloc: Alloc, a: f32, b: f32, c1: f32, xs: *Tensor(f32), ys: *Tensor(f32)) !QuadraticModel {
        var p = QuadraticModel{
            // zig fmt: off
            .params = .{ 
                try Tensor(f32).initScalar(alloc, a), 
                try Tensor(f32).initScalar(alloc, b), 
                try Tensor(f32).initScalar(alloc, c1) 
            },
            // zig fmt: on
            .g = ComputeGraph(f32).init(alloc),
            .out = undefined,
            .loss = undefined,
        };
        for (p.params) |param| {
            try param.setParam();
        }
        const xsq = try xs.sqr(); // x^2
        xsq.name = "x^2";
        const axsq = try xsq.mul(try p.params[0].repeatLike(xsq)); // a*x^2
        axsq.name = "a*x^2";
        const bx = try xs.mul(try p.params[1].repeatLike(xs)); // b*x
        bx.name = "b*x";
        const axsqPlusBx = try axsq.add(bx); // a*x^2 + b*x
        axsqPlusBx.name = "a*x^2 + b*x";

        p.out = try axsqPlusBx.add(try p.params[2].repeatLike(xs)); // a*x^2 + b*x + c
        p.out.name = "a*x^2 + b*x + c";
        p.loss = try mseFunc(p.out, ys);
        p.loss.name = "loss";
        try p.g.buildForward(p.loss);
        try p.g.buildBackward(true);
        return p;
    }

    fn deinit(self: *Self) void {
        self.g.deinit();

        // for (self.params) |p| {
        //     p.deinit();
        // }
    }

    fn compute(self: *Self) void {
        self.g.resetGrads();
        self.g.compute();
    }

    fn step(self: *Self, lr: *Tensor(f32)) void {
        for (self.params) |p| {
            const g = p.grad.?;
            g.computeMul(g, lr);
            p.computeSub(p, g);
        }
    }
};

// TODO: fix for broadcast
test "QuadraticModel" {
    const time = try Tensor(f32).initArange(tac, &.{20}, 0, 20);
    const speed = try Tensor(f32).initArange(tac, &.{20}, 5, 25);

    var model = try QuadraticModel.build(tac, 0.01, 0.01, 0.01, time, speed);
    {
        const dotviz = try model.g.toGraphViz();
        defer dotviz.deinit();
        std.debug.print("{s}\n", .{dotviz.items});
    }
    defer model.deinit();
    const lr = try Tensor(f32).initScalar(tac, 0.01);
    defer lr.deinit();

    for (0..10) |_| {
        model.compute();
        // {
        //     const dotviz = try model.g.toGraphViz();
        //     defer dotviz.deinit();
        //     std.debug.print("{s}\n", .{dotviz.items});
        // }
        model.step(lr);
        std.debug.print("loss: {d}\n", .{model.loss.data[0]});
    }
}
