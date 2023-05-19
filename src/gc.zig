const std = @import("std");
const Allocator = Allocator;
const Value = @import("Value.zig");
const interpreter = @import("interpreter.zig").interpreter;

const root = @import("root");

const Gc = @This();

/// The allocator used to allocate and free memory of the stack
gpa: *Allocator,
/// The stack that contains each allocated Value, used to track and then free its memory
/// `stack` is a linked list to other Values
stack: ?*Value,
/// Reference to the interpreter, used to retrieve the current stack and globals so we can
/// mark the correct values before sweeping
interpreter: *interpreter,
/// Size of currently allocated stack
newly_allocated: usize,

/// Initializes a new `GarbageCollector`, calling deinit() will ensure all memory is freed
pub fn init(allocator: *Allocator) Gc {
    return .{
        .gpa = allocator,
        .stack = null,
        .interpreter = undefined,
        .newly_allocated = 0,
    };
}

/// Inserts a new `Value` onto the stack and allocates `T` on the heap
pub fn newValue(self: *Gc, comptime T: type, val: T) !*Value {
    const typed = try self.gpa.create(T);

    typed.* = val;
    typed.base.next = self.stack;

    self.stack = &typed.base;

    // In the future we could implement the Allocator interface so we get
    // direct access to the bytes being allocated, which will also allow tracking
    // of other allocations such as strings, lists, etc
    self.newly_allocated += @sizeOf(T);
    if (self.newly_allocated >= self.trigger_size) {
        //also mark currently created so it doesn't get sweeped instantly
        self.mark(&typed.base);
        self.markAndSweep();
    }

    return &typed.base;
}

/// Marks an object so it will not be sweeped by the gc.
pub fn mark(self: *Gc, val: *Value) void {
    if (val.is_marked) return;

    val.is_marked = true;
    switch (val.ty) {
        .iterable => self.mark(val.toIterable().value),
        .list => for (val.toList().value.items) |item| self.mark(item),
        .map => {
            for (val.toMap().value.items()) |entry| {
                self.mark(entry.key);
                self.mark(entry.value);
            }
        },
        else => {},
    }
}

/// Destroys all values not marked by the garbage collector
pub fn sweep(self: *Gc) void {
    if (self.stack == null) return;

    var prev: ?*Value = null;
    var next: ?*Value = self.stack;
    while (next) |val| {
        next = val.next;
        if (!val.is_marked) {
            if (prev) |p| p.next = next else self.stack = next;
            val.destroy(self.gpa);
        } else {
            val.is_marked = false;
            prev = val;
        }
    }
}

/// Finds all referenced values in the interpreter, marks them and finally sweeps unreferenced values
fn markAndSweep(self: *Gc) void {
    for (self.interpreter.globals.items) |global| self.mark(global);
    for (self.interpreter.call_stack.items) |cs| if (cs.fp) |func| self.mark(func);
    for (self.interpreter.locals.items) |local| self.mark(local);
    for (self.interpreter.stack[0..self.interpreter.sp]) |stack| self.mark(stack);
    for (self.interpreter.libs.items()) |lib_entry| self.mark(lib_entry.value);

    self.sweep();
    self.newly_allocated = 0;
}

/// Frees the `stack` that still exist on exit
pub fn deinit(self: *Gc) void {
    while (self.stack) |next| {
        const temp = next.next;
        next.destroy(self.gpa);
        self.stack = temp;
    }
    self.* = undefined;
}
