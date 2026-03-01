# MQuickJS Main Application - Test Flow Documentation

本文档详细描述了 `main.c` 中的测试流程和架构设计。

## 概述

`main.c` 是 MQuickJS JavaScript 引擎与 Bouffalo SDK 的集成入口，实现了：
- FreeRTOS 任务管理
- Shell 命令交互
- JavaScript 运行时环境
- LittleFS 文件系统访问

---

## 启动流程

### 启动时序图

```
main()
  │
  ├─> board_init()                       // 硬件初始化
  │
  ├─> Print banner                       // 打印欢迎信息
  │
  ├─> xQueueCreate(4, js_request_t)      // 创建 JS 请求队列
  │
  ├─> xTaskCreate(js_vm_task, ...)       // 创建 JS VM 专用任务
  │     │
  │     └─> js_vm_task() [独立任务]
  │           │
  │           ├─> pvPortMalloc(64KB)     // 分配 JS 堆内存
  │           │
  │           ├─> JS_NewContext()        // 初始化 JS 虚拟机
  │           │
  │           ├─> JS_SetLogFunc()        // 设置日志输出函数
  │           │
  │           ├─> JS_SetRandomSeed()     // 设置随机数种子
  │           │
  │           └─> 主循环:
  │                 ├─> xQueueReceive()    // 等待 Shell 请求 (100ms 超时)
  │                 │   ├─> 收到请求:
  │                 │   │   ├─> load_js_file()   // 从 LittleFS 加载脚本
  │                 │   │   ├─> JS_Eval()        // 执行 JavaScript
  │                 │   │   └─> xSemaphoreGive() // 通知完成
  │                 │   └─> 超时: run_timers()   // 处理定时器
  │                 └─> 循环继续...
  │
  ├─> shell_init_with_task(uart0)        // 启动 Shell 交互
  │
  └─> vTaskStartScheduler()              // 启动 FreeRTOS 调度器
```

### 初始化步骤详解

| 步骤 | 函数 | 说明 |
|------|------|------|
| 1 | `board_init()` | 初始化时钟、GPIO、UART 等硬件 |
| 2 | `xQueueCreate(4, sizeof(js_request_t))` | 创建可容纳 4 个请求的队列 |
| 3 | `xTaskCreate(js_vm_task, "JS_VM", 8KB, ...)` | 创建 JS VM 任务，优先级 5 |
| 4 | `shell_init_with_task(uart0)` | 初始化 UART Shell |
| 5 | `vTaskStartScheduler()` | 启动多任务调度 |

---

## Shell 命令

### 命令一览

| 命令 | 功能 | 示例 |
|------|------|------|
| `js_run <filename>` | 从 LittleFS 运行 JS 文件 | `js_run /lfs/hello.js` |
| `js_eval "<expr>"` | 执行内联 JS 表达式 | `js_eval "print(1+2)"` |
| `js_info` | 显示 VM 配置信息 | `js_info` |

### js_run 命令流程

```
用户输入: js_run /lfs/hello.js
    │
    ▼
cmd_js_run(argc, argv)
    │
    ├─> 创建请求:
    │     req.filename = "/lfs/hello.js"
    │     req.done = xSemaphoreCreateBinary()
    │     req.result = -1
    │
    ├─> xQueueSend(js_queue, &req)    // 发送到 JS VM 任务
    │
    ├─> xSemaphoreTake(req.done)      // 等待执行完成
    │
    │   [JS VM 任务侧]
    │   js_vm_task():
    │     ├─> xQueueReceive() 收到请求
    │     ├─> load_js_file("/lfs/hello.js")
    │     ├─> JS_Eval(script, len, filename, 0)
    │     │     ├─> 成功: req.result = 0
    │     │     └─> 异常: 打印错误，req.result = -1
    │     └─> xSemaphoreGive(req.done)
    │
    └─> 打印执行结果
```

### js_eval 命令流程

```
用户输入: js_eval "print(1+2)"
    │
    ▼
cmd_js_eval(argc, argv)
    │
    ├─> malloc(64KB)                   // 临时分配内存
    │
    ├─> JS_NewContext(mem, 64KB)       // 创建临时 JS 上下文
    │
    ├─> JS_SetLogFunc()                // 设置输出
    │
    ├─> JS_Eval("print(1+2)", ...)     // 直接执行
    │     ├─> 调用 js_print()
    │     └─> 输出: 3
    │
    ├─> JS_FreeContext()               // 释放上下文
    │
    └─> free()                         // 释放内存
```

**注意**: `js_eval` 使用独立的内存空间，每次执行都会创建和销毁 JS 上下文。

### js_info 命令输出

```
MQuickJS on Bouffalo SDK
  JS Heap: 65536 bytes
  Task Stack: 8192 bytes
  Max Script: 32768 bytes

Commands:
  js_run <file>  - Run JS from LittleFS
  js_eval <expr> - Evaluate JS expression
```

---

## JS VM 任务架构

### 任务配置

```c
#define JS_MEM_SIZE         (64 * 1024)   // 64KB JS 堆内存
#define JS_TASK_STACK_SIZE  (8 * 1024)    // 8KB 任务栈
#define JS_TASK_PRIORITY    5             // 任务优先级
#define JS_MAX_SCRIPT_SIZE  (32 * 1024)   // 32KB 最大脚本尺寸
```

### 请求队列结构

```c
typedef struct {
    char filename[256];           // JS 文件路径
    SemaphoreHandle_t done;       // 完成信号量
    int result;                   // 执行结果 (0=成功, -1=失败)
} js_request_t;
```

### 任务主循环逻辑

```c
while (1) {
    // 100ms 超时等待请求
    if (xQueueReceive(js_queue, &req, pdMS_TO_TICKS(100)) == pdTRUE) {
        // 有请求：执行 JS 文件
        script = load_js_file(req.filename, &len);
        JS_Eval(ctx, script, len, req.filename, 0);
        xSemaphoreGive(req.done);  // 通知完成
    } else {
        // 无请求：处理定时器
        run_timers(ctx);
    }
}
```

---

## 运行时函数

### JavaScript API 映射

| JS API | C 函数 | 功能 |
|--------|--------|------|
| `Date.now()` | `js_date_now()` | 返回当前时间戳 (ms) |
| `performance.now()` | `js_performance_now()` | 高精度时间戳 (ms) |
| `print(...args)` | `js_print()` | 控制台输出 |
| `gc()` | `js_gc()` | 触发垃圾回收 |
| `setTimeout(fn, delay)` | `js_setTimeout()` | 设置定时器 |
| `clearTimeout(id)` | `js_clearTimeout()` | 清除定时器 |
| `load(filename)` | `js_load()` | 加载执行 JS 文件 |

### 定时器实现

```c
typedef struct JSTimer {
    struct JSTimer *prev;
    struct JSTimer *next;
    int64_t timeout;      // 过期时间 (ms)
    JSValue func;         // 回调函数
    int id;               // 定时器 ID
} JSTimer;
```

定时器在 `js_vm_task` 主循环空闲时（无请求）被检查和执行。

---

## FreeRTOS 钩子函数

### 栈溢出检测

```c
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName)
{
    printf("\r\n[STACK OVERFLOW] %s\r\n", pcTaskName);
    while (1);  // 死循环
}
```

### 内存分配失败

```c
void vApplicationMallocFailedHook(void)
{
    printf("\r\n[MALLOC FAILED]\r\n");
    while (1);  // 死循环
}
```

---

## 错误处理

### JS 执行错误

```c
if (JS_IsException(val)) {
    JSValue exc = JS_GetException(ctx);
    printf("JS Error: ");
    JS_PrintValueF(ctx, exc, JS_DUMP_LONG);
    printf("\r\n");
}
```

### 文件加载错误

| 错误类型 | 输出信息 |
|----------|----------|
| 文件不存在 | `Error: Cannot open /lfs/xxx.js` |
| 脚本过大 | `Error: Script too large (x > 32768)` |
| 内存不足 | `Error: Out of memory` |

---

## 内存布局

```
┌─────────────────────────────────────────────────────┐
│                    RAM (447KB)                       │
├─────────────────────────────────────────────────────┤
│  JS VM Task Stack (8KB)                             │
├─────────────────────────────────────────────────────┤
│  JS Heap (64KB) - pvPortMalloc                      │
├─────────────────────────────────────────────────────┤
│  Shell Task Stack                                   │
├─────────────────────────────────────────────────────┤
│  System Heap (TLSF)                                 │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│                   XIP Flash (4MB)                    │
├─────────────────────────────────────────────────────┤
│  Firmware Code (~220KB)                             │
├─────────────────────────────────────────────────────┤
│  LittleFS Partition                                 │
│   - /lfs/*.js (用户脚本)                            │
└─────────────────────────────────────────────────────┘
```

---

## 使用示例

### 运行脚本文件

```bash
# 1. 先将 JS 文件写入 LittleFS（需要其他工具）
# 2. 在串口终端执行:

bouffalo> js_run /lfs/hello.js
Hello from JavaScript!
JS executed successfully
```

### 内联执行

```bash
bouffalo> js_eval "print(1 + 2)"
3

bouffalo> js_eval "for (let i = 0; i < 3; i++) print(i)"
0
1
2

bouffalo> js_eval "Date.now()"
1709250123456
```

### 查看配置

```bash
bouffalo> js_info
MQuickJS on Bouffalo SDK
  JS Heap: 65536 bytes
  Task Stack: 8192 bytes
  Max Script: 32768 bytes
```

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `main.c` | 主程序入口 |
| `mquickjs.c` | JS 引擎核心 |
| `mquickjs.h` | JS API 头文件 |
| `mqjs_stdlib.h` | 生成的标准库表 |
| `cutils.c` | 工具函数 |
| `libm.c` | 数学库 |
| `dtoa.c` | 浮点转换 |
