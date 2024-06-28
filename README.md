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
- [Vulkan youtube series by Codotaku](https://www.youtube.com/watch?v=Kf7BIPUUfsc) with [source code](https://github.com/CodesOtakuYT/vulkan_zig)
- [Vulkan & SDL2 by Codotaku](https://www.youtube.com/playlist?list=PLlKj-4rp1Gz2KfP0B0XN2a5i-WFjhyzrh) with [source](https://github.com/CodesOtakuYT/zig_vk)
