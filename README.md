# vulkan experiments

## running

Run the application
```bash
zig build run
```

Run the application and debug print the vulkan api calls
```bash
VK_INSTANCE_LAYERS=VK_LAYER_LUNARG_api_dump zig build run
```

Alternatively, use `vkconfig` for more fine grained layers config.


## ressources
- [Vulkan Tutorial](https://vulkan-tutorial.com/)
- [Vulkan youtube series by Codotaku](https://www.youtube.com/watch?v=Kf7BIPUUfsc)
- [sample code by Codotaku - zig_vk](https://github.com/CodesOtakuYT/zig_vk)
- [sample code by Codotaku - vulkan_zig](https://github.com/CodesOtakuYT/vulkan_zig)
