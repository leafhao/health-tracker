# 本机 Agent API

Receiver 为同一台电脑上的 AI Agent 提供只读、免 Token 的结构化健康上下文。接口只接受同时满足以下条件的请求：

- TCP 客户端来自回环地址；
- URL 主机也是 `127.0.0.1`、`localhost` 或 `::1`。

因此局域网 IP、Tailscale 域名和公网反向代理都不能使用这些接口。默认响应不包含原始样本、原始 metadata 或精确 GPS 坐标。

## 接口

### 数据字典

```bash
curl http://127.0.0.1:8787/api/v1/agent/catalog
```

这是 Agent 理解数据的权威入口。每个指标都说明：

- `group`：所属领域；
- `unit`：单位；
- `acquisition`：从哪个 HealthKit 类型或物化结果获得；
- `calculation`：Receiver 如何去重、聚合或推导；
- `meaning`：指标支持什么判断；
- `caveat`：不能据此推出什么结论。

`workout_fields` 单独解释单次训练的字段；`missing_reasons` 解释空值原因；`series_metrics` 是允许查询历史序列的白名单。

### 单日健康上下文

```bash
curl http://127.0.0.1:8787/api/v1/agent/context/2026-08-27
```

响应包含：

- `completeness`：数据截止时间、当天是否完整、规整状态、待处理任务和同步序列缺口；
- `activity`：步数、距离、能量、锻炼、站立和楼层；
- `sleep`：主睡眠、午睡、阶段、效率、连续率及睡眠期生命体征；
- `cardio_recovery`：静息心率、HRV、呼吸率、血氧、VO₂ Max 和心率恢复；
- `body`：体重、体脂率、BMI 和去脂体重，以及实际测量时间和直接读取/计算来源；
- `training_summary`：训练次数、时长、能量、心率覆盖、五区时长和加权负荷；
- `workouts`：单次训练专项指标，但不含精确坐标；
- `personal_baselines`：此前 28 天个人中位数；
- `regularity`：通常入睡/起床时间及波动；
- `recovery_reference`：睡眠、HRV、静息心率相对个人基线的确定性比较；
- `training_load_context`：近 7 天与此前 4 周的训练负荷背景；
- `trends`：7、28、90 天关键指标摘要；
- `deterministic_signals`：只描述事实变化，不生成医学诊断或训练处方；
- `data_quality`：设备能力、权限状态、样本覆盖、来源规则及缺失原因。

查询其他时区时可传 `timezone_name`。系统当前默认使用 `Asia/Shanghai`。

### 指标序列

```bash
curl 'http://127.0.0.1:8787/api/v1/agent/series/hrv_sdnn_ms?from_date=2026-08-01&to_date=2026-08-27'
```

序列接口只接受数据字典列出的指标，单次最多 365 天。响应同时包含字段定义、有效天数、均值、中位数、范围、首末变化率和方向。对 VO₂ Max、体重、体脂率、BMI、去脂体重和心率恢复等非每日测量指标，每个点还会包含实际测量时间。

## 分析日语义

- 活动和训练归属目标日期本地时间 `00:00–24:00`；
- 睡眠窗口为目标日期前一天 `18:00` 到目标日期 `18:00`；
- 最长合并睡眠时段为主睡眠，其余为午睡；
- Apple Watch 分期睡眠覆盖的时段由分期数据负责，AutoSleep 等未分期来源只补充未覆盖睡眠；
- 当查询今天时，`is_complete_day` 为 `false`，Agent 不应把当前累计值与完整历史日直接比较。

## Agent 使用原则

1. 先读取一次 `catalog`，按其中单位和口径解释字段。
2. 日常分析优先读取 `context/{date}`，不要扫描原始表或抓取 Dashboard HTML。
3. 只有需要验证趋势时才读取 `series`，避免把大量分钟样本塞入上下文。
4. 空值必须结合 `data_quality.metric_status` 判断，不能当成零。
5. Receiver 的确定性信号是个人基线比较；Agent 生成的建议必须保留非医学诊断边界。
