const std = @import("std");
const sdl = @import("sdl2");
const vk = @import("vulkan");

pub const vkAPIs: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{
            .createInstance = true,
        },
        .instance_commands = .{
            .createDevice = true,
        },
    },
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

pub const Allocator = std.mem.Allocator;
pub const BaseDispatch = vk.BaseWrapper(vkAPIs);
pub const InstanceDispatch = vk.InstanceWrapper(vkAPIs);
pub const DeviceDispatch = vk.DeviceWrapper(vkAPIs);
pub const Instance = vk.InstanceProxy(vkAPIs);
pub const Device = vk.DeviceProxy(vkAPIs);

const DeviceCandidate = struct {
    physical_device: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

pub const GraphicsContext = struct {
    allocator: Allocator,
    instance: Instance,
    device: Device,
    surface: vk.SurfaceKHR,

    graphics_queue: Queue,
    present_queue: Queue,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: sdl.Window) !GraphicsContext {
        var self: GraphicsContext = undefined;
        self.allocator = allocator;

        try sdl.vulkan.loadLibrary(null);
        const vkb = try BaseDispatch.load(try sdl.vulkan.getVkGetInstanceProcAddr());
        const extensions = try sdl.vulkan.getInstanceExtensionsAlloc(window, allocator);
        defer allocator.free(extensions);

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .p_engine_name = app_name,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_2,
        };
        // Basic zig-ified vulkan instance
        const instance_handle = try vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = @ptrCast(extensions),
        }, null);

        // Basic zig-ified function calls related to the vulkan instance
        const vk_instance_wrapper = try allocator.create(InstanceDispatch);
        errdefer allocator.destroy(vk_instance_wrapper);
        vk_instance_wrapper.* = try InstanceDispatch.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr);

        // Zig-ified vulkan instance and function calls tied in a nice bow!
        const instance = Instance.init(instance_handle, vk_instance_wrapper);
        errdefer instance.destroyInstance(null);

        const surface = try sdl.vulkan.createSurface(window, instance.handle);
        errdefer instance.destroySurfaceKHR(surface, null);

        const physical_device = try pickPhysicalDevice(instance, allocator, surface);
        const priority = [_]f32{1};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = physical_device.queues.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = physical_device.queues.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };
        const queue_count: u32 = if (physical_device.queues.graphics_family == physical_device.queues.present_family) 1 else 2;
        const device_handle = try instance.createDevice(physical_device.physical_device, &.{
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &qci,
            .enabled_extension_count = required_device_extensions.len,
            .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        }, null);
        const device_wrapper = try allocator.create(DeviceDispatch);
        errdefer allocator.destroy(device_wrapper);
        device_wrapper.* = try DeviceDispatch.load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr);

        const device = Device.init(device_handle, device_wrapper);
        errdefer device.destroyDevice(null);

        self.instance = instance;
        self.surface = surface;
        self.device = device;
        self.graphics_queue = Queue.init(device, physical_device.queues.graphics_family);
        self.present_queue = Queue.init(device, physical_device.queues.present_family);
        return self;
    }

    pub fn deinit(self: GraphicsContext) void {
        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);

        self.allocator.destroy(self.device.wrapper);
        self.allocator.destroy(self.instance.wrapper);
    }
};

pub fn pickPhysicalDevice(
    instance: Instance,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkDeviceSuitable(instance, pdev, surface, allocator)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkDeviceSuitable(instance: Instance, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, allocator: std.mem.Allocator) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, physical_device, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, physical_device, surface)) {
        return null;
    }

    if (try allocateQueues(instance, physical_device, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(physical_device);
        return DeviceCandidate{
            .physical_device = physical_device,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};
fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}
