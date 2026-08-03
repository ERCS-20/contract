# Perps 合约开发：待决问题清单

> **主路径已决：系统账户 + 强平接仓 + 触线 ADL**  
> 下列「建议默认」已于 2026-08-03 按讨论采纳，可开写骨架。

相关文档：[`../README.md`](../README.md) · [`TRADER_SETTLEMENT_GUIDE.md`](./TRADER_SETTLEMENT_GUIDE.md) · [`REF_DYDX_PERPETUAL_V1.md`](./REF_DYDX_PERPETUAL_V1.md)

---

## 0. 主路径（已决）

```text
每市场系统账户 S = 现金 + 强平接仓
强平：margin → S 现金；仓位 owner → S
无 Claim；S 权益 ≤ 固定阈值 → ADL
阈值设入时按总金额约 8% 算成绝对数；合约只比较固定值
成交：引擎报 fill，合约校验后记账（A4=C）
```

---

## 已决 / 采纳默认

| 题 | 状态 | 结论 |
|----|------|------|
| A1 | 已决 | 仓位上链 |
| A2 | 已决 | AllowedKeys + 用户订单 EIP-712；强平/ADL 不验被处置方签 |
| A3 | 已决 | 多 marketId；统一保证金；仅 USDC；每市场 S |
| A4 | 已决 | **C**：引擎 fill + 链上校验 |
| A5 | 取消 | 无 Claim |
| B1 | 已决 | 独立 Perps 金库 |
| B2 | 已决（默认） | 充值开放；提现 withdrawDAO EIP-712；强提 7 日；**有仓不可强提清仓**（须先平仓） |
| B3 | 已决（v0） | 强平剩余 → S；S 平仓盈亏留在 S；罚金/手续费/资金费 skim **暂缓** |
| C1 | 已决（v0） | 开平仓 + 强平进 S + ADL；资金费暂缓 |
| C2 | 已决 | 学 dYdX：`trade` 批次 + 强平/ADL 专用入口（或 trader 插件） |
| C3 | 已决 | 合约不硬顶；引擎按 gas 拆批 |
| D1 | 暂缓 | v0 资金费不上链 |
| D2 | 已决 | 要 ADL；**链下排序（盈利率优先）**，链上执行与 S 对敲/强制减仓 |
| D3 | 已决 | 敞口 = S 仓位 |
| D4 | 取消 | 无 MCR |
| E1 | 已决（默认） | Pausable + Ownable |
| E2 | 已决（默认） | 强提仅链上可用余额；有仓须先平 |
| E3 | 已决 | `perps/contracts`，Solidity **0.8.28**，风格对齐 spot |
| F | 已决（v0） | 充提 + 开平仓 + S + 强平 + ADL 阈值；Claim/PP/MCR/资金费不做 |

---

## 实现中仍可微调（不挡骨架）

1. ADL 排序权重细节（链下）  
2. 维持保证金率 / 强平线具体数值（`liquidate` 暂不校验抵押率，由 operator 保证）  
3. 预言机适配器（Chainlink 等）  
4. Spot↔Perps Bridge  
5. 正常成交兑付不足时的策略（v0 对普通 `settleTrades` 严格要求 S 现金够付；ADL 允许 haircut）

> **抵押品：** ARC 原生 USDC（18 位）；Perps 金库直接托管原生币，不 wrap WUSDC（与 Spot 多币种金库不同）。

### 骨架落地（2026-08-03）

```text
perps/contracts/
  GlobalPerpsVault.sol    # 原生 USDC 充提 / 强提 / 用户↔S 调账
  PerpsExchange.sol       # 多市场、仓位、S、settleTrades / liquidate / executeAdl
  libraries/PerpsTypes.sol, PerpsMath.sol
  interfaces/, mocks/
```

`npx hardhat test`：数学单测 + 充提/成交/强平进 S/触线 ADL。

---

## 解答记录

| 题号 | 状态 | 日期 |
|------|------|------|
| 主路径 / A1–A5 / B1 / D2–D4 | 已决或取消 | 2026-08-03 |
| B2 B3 C1–C3 D1 E1–E3 F | 按建议默认已决/暂缓 | 2026-08-03 |
| A4 | C | 2026-08-03 |
