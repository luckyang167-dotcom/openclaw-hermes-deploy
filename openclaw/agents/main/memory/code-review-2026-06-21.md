# 🔍 代码审查报告 — 多功能公寓灯系统

**项目**: 1.3多功能公寓灯 (STC8H, C语言)
**审查日期**: 2026-06-21
**审查范围**: System/ → User/ → BSP/ → CSP/ 四层架构

---

## 一、总体评价

项目采用清晰的 **System → User → BSP → CSP** 四层架构，时间片轮转调度 + 状态机模式设计合理，是课程设计级别的优秀作品。

| 维度 | 评价 |
|------|------|
| 架构分层 | ⭐⭐⭐⭐⭐ (清晰，职责分明) |
| 任务调度 | ⭐⭐⭐⭐ (时间片轮转，可配置周期) |
| 代码风格 | ⭐⭐⭐ (有注释，但过度) |
| 可维护性 | ⭐⭐⭐ (状态机可改进为数据驱动) |
| 移植性 | ⭐⭐⭐ (多BSP目录，但未明确选择) |

---

## 二、代码亮点 ✅

### 2.1 分层架构清晰
```
System/  →  系统入口 + 任务调度
User/    →  应用逻辑 (MFAL/LED/Key/LDR)
BSP/     →  板级支持包 (GPIO/传感器)
CSP/     →  芯片级驱动 (PWM/UART/EEPROM/I2C)
```
每一层职责单一，这是嵌入式项目应当坚持的好习惯。

### 2.2 时间片任务调度
`Task.c` 实现了经典的 `TASK_COMPONENTS` 时间片轮转调度器，用结构体数组配置任务周期，在中断中递减计数器，在主循环中执行就绪任务。代码简洁，可扩展。

### 2.3 模式状态机
`User_MFAL_Control()` 采用双层状态机（模式→子模式），3种主模式 + 各子模式，逻辑清晰，便于添加新模式。

### 2.4 Doxygen 风格注释
每个文件/函数都有 `@brief @details @note @return` 注释，非常适合课程设计评分和团队协作。

---

## 三、问题与改进建议 ⚠️

### 3.1 🔴 严重问题：BSP 函数编译风险

**文件**: `BSP/BSP_STC8H1K28_32/LED.c`

```c
// 第73-90行: LED_Set() 被 #if 0 整个禁用了！
#if 0
void LED_Set(uint8 led_color,uint8 led_set) { ... }
#endif
```

但 `User_MFAL.c` 中反复调用 `LED_Set()`。
如果编译器选中了这个BSP目录，**编译会直接报错**。

**建议**:
- 统一 BSP 目录选择机制（通过 `Config.h` 或 Makefile 决定引用哪个 BSP）
- 清理 `#if 0` 废弃代码
- 或者：将 `LED_Set()` 以外的 `LED_Solo/LED_Off` 也统一归入 `LED_Set` 实现

### 3.2 🟠 按键消抖阻塞调度器

**文件**: `BSP/BSP_STC8H1K28_32/Key.c`

```c
// 在 task 每 50ms 调用的 User_MFAL_Control() 内部
// Key_GetNum() 会执行：
Delay20ms();        // 阻塞 20ms
while(Key1 == 0);   // 等待按键释放，可能阻塞 100ms+
Delay20ms();        // 再阻塞 20ms
```

任务周期是 **50ms**，一个按键按下可能阻塞 **150ms 以上**。这会直接拖垮整个调度系统。

**建议**:
- 将按键扫描改为 **非阻塞状态机**：每次调用只采样一次，用状态机管理按下/释放/消抖
- 典型做法：`static uint8 key_state` + `uint8 key_pin = Key1` → 状态切换，不阻塞

### 3.3 🟠 SOS 状态机维护成本高

**文件**: `User/User_LED.c` — `User_LED_SOS()`

19 个 case (0-18) 的手工状态编码，每个case里硬编码时长（10、5、30、15）。

```c
case 0: if (sos_timer >= 10) { ... sos_state = 1; }
case 1: if (sos_timer >= 5)  { ... sos_state = 2; }
// ... 重复 19 次
```

- 如果要调整 SOS 速度 → 需要改 19 个 magic number
- 如果要增加新的摩尔斯码 → 需要重新设计

**建议** → **数据驱动设计**:

```c
typedef struct {
    uint8 duration;   // 持续时间（时间单位数）
    uint8 led_on;     // 该时段LED是否点亮
} sos_segment_t;

// SOS = ... --- ...  = 3短 3长 3短
const sos_segment_t sos_pattern[] = {
    {10, 1}, {5, 0}, {10, 1}, {5, 0}, {10, 1}, {15, 0},   // S ...
    {30, 1}, {5, 0}, {30, 1}, {5, 0}, {30, 1}, {15, 0},   // O ---
    {10, 1}, {5, 0}, {10, 1}, {5, 0}, {10, 1}, {5, 0},    // S ...
    {30, 0},                                              // 单词间隔
};
```

这样改速度只需调数据表，代码缩到 15 行。

### 3.4 🟡 浮点运算在 8 位 MCU

**文件**: `CSP/PWM.c`

```c
match_temp = period_temp * ((float)duty / PWM_DUTY_MAX);   // float!
```

STC8H 没有硬件浮点单元，`float` 运算会引入 **大量软件模拟开销**（数KB代码 + 慢几十倍）。

**建议** → 定点运算:

```c
// 先乘后除，避免 overflow
// PWM_DUTY_MAX = 1000, period_temp 最大 ~65535
match_temp = (uint16)(((uint32)period_temp * duty) / PWM_DUTY_MAX);
```

### 3.5 🟡 类型命名混乱

**文件**: `System/Type_def.h`

```c
typedef unsigned char   u8;      // 简短风格
typedef unsigned char   uint8;   // 标准风格
typedef unsigned char   uint8_t; // C99风格
```

三个名字指向同一个类型。代码中混用：
- `Task.c` 用 `u8`
- `User_MFAL.c` 用 `uint8`
- `User_LED.c` 用 `uint8` 和 `uint8_t`

**建议**: 统一为一种风格（推荐 `uint8_t`/C99标准），删除多余定义。

### 3.6 🟡 Task.h 头文件过度包含

**文件**: `System/Task.h`

```c
#include "User_LED.h"
#include "User_Key.h"
#include "User_LDR.h"
#include "User_MFAL.h"
```

任务调度器头文件不应该知道上层应用的存在。这会导致：
- 循环依赖风险
- 任何 User 层文件的修改都会触发整个工程重编译

**建议**:
- `Task.h` 只包含 `Timer.h` 和 `Type_def.h`
- `setup()` 中的应用初始化放到 `main.c` 或单独的 `App_Init()` 中

### 3.7 🟡 LED 枚举 vs 宏混用

**BSP层宏**: `LED_B` `LED_R` `LED_G` → `LED_ON(0)` `LED_OFF(1)`
**User层枚举**: `LED_RED` `LED_BLUE` `LED_GREEN` → `LED_ON` `LED_OFF`

同一定义出现在两处，如果未来修改映射，两边不同步会导致 bug。

**建议**:
- 只在 BSP 层定义一次 LED 编号和 ON/OFF
- User 层通过 BSP 接口调用，不重复定义

### 3.8 🟢 建议性：LED_Off() 可复用 LED_Set()

```c
// 当前: User_MFAL_DailyMode() 中
LED_Off();
LED_Set(LED_CORE_LED, LED_OFF);
// 两次函数调用，LED_Off() 之后又单独关一个灯

// 改: LED_Off() 内部调用 LED_Set() 实现，不重复
```

### 3.9 🟢 建议性：取消 User_Key.c 中的废弃代码

`User_Key.c` 中保留了大量 `#if 0` 废弃代码（~150行），包括 Key_Ctrl_PWM、Key_Mode_Fan 等属于其他项目的代码。建议清理或归档到 separate repo。

### 3.10 🟢 建议性：注释密度过高

每个 .c 和 .h 文件头部有 **8行版权声明**，每个函数有 5-10 行 doxygen 注释，包括 `LED_Off()`（3行有效代码，9行注释）。过多的模板注释会降低信噪比。

**建议**:
- header 注释保留，但不必为每个 getter/setter 写 `@details @note @example`
- `.c` 中的函数注释可以简化为 `// brief description` 而非完整 doxygen 块
- 版权声明可以用 SPDX 格式精简：`// SPDX-License-Identifier: ...`

---

## 四、优先级总结

| 优先级 | 问题 | 工作量 |
|--------|------|--------|
| P0 🔴 | BSP 函数被 #if 0 禁用 | 1h — 选一个BSP并修复函数 |
| P1 🟠 | 按键阻塞调度器 | 3h — 改为状态机扫描 |
| P1 🟠 | SOS 状态机改为数据驱动 | 1h — 定义数据表+循环 |
| P2 🟡 | PWM 浮点改为定点 | 0.5h |
| P2 🟡 | 统一类型命名 | 0.5h |
| P2 🟡 | Task.h 过度包含 | 0.5h |
| P3 🟢 | 清理 #if 0 废弃代码 | 1h |
| P3 🟢 | 精简模板注释 | 0.5h |

---

## 五、给 Locky 的成长建议

1. **习惯「非阻塞」思维**：在 RTOS 或时间片调度系统中，任何 `while` 等待都是不可取的。练习用状态机替代延时。
2. **数据驱动 > 代码驱动**：能用数组/表解决的就别用手工 case。SOS、LED 效果、菜单选项等，数据表 + 循环更优雅。
3. **慎用 float**：8 位 MCU 没有 FPU，定点算术是嵌入式工程师的基本功。
4. **控制编译单元依赖**：头文件包含的原则是「只包含你真正需要的」，避免耦合。
5. **清理代码仓库**：`#if 0` 废弃代码是技术债。用 Git 管理版本，不用的代码就删掉。

---

*审查人: Programming Partner @ Locky's Workspace*
