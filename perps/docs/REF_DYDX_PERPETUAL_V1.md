# 参考：dYdX Perpetual V1（本地代码）

> 路径：`/Users/if/Work/dydx/perpetual/`  
> 版本：Solidity **0.5.16**，Truffle；我们后续目标 **0.8.28** + Hardhat。  
> 性质：链上保证金 + 链上仓位的永续（**不是** StarkEx / V3 ZK 那套）。

本文只做架构对照，方便写我们自己的合约时「抄结构、不抄产品语义」。

---

## 1. 它是什么

一笔永续市场 ≈ 一个 `PerpetualV1`（可代理）：

- 一种保证金币 `_TOKEN_`
- 价格预言机 `_ORACLE_`
- 资金费率合约 `_FUNDER_`
- 最低抵押率 `_MIN_COLLATERAL_`

用户账户在链上就是一个 `Balance`：

```solidity
// P1Types.Balance
bool marginIsPositive;
bool positionIsPositive;
uint120 margin;    // 保证金（带符号拆成正负标志）
uint120 position;  // 仓位数量（带符号）
```

**仓位上链、保证金上链** —— 和我们「MCR 链下、可选仓位不上链」是不同选项；若选 A1=上链，最接近这套。

---

## 2. 核心模块（合约树）

| 模块 | 文件 | 职责 |
|------|------|------|
| 门面 | `PerpetualV1.sol` | 组装 Admin / Margin / Trade / Getters… |
| 存储 | `impl/P1Storage.sol` | balances、index、operators、oracle… |
| 资金费结算 | `impl/P1Settlement.sol` | 全局 Index + 按账户懒结算 funding |
| 交易批次 | `impl/P1Trade.sol` | `trade(accounts, trades[])` |
| 充提 | `impl/P1Margin.sol` | `deposit` / `withdraw`（提现后须仍足抵押） |
| 订单成交 | `traders/P1Orders.sol` | EIP-712 限价单，实现 `I_P1Trader` |
| 清算 | `traders/P1Liquidation.sol` | 不足抵押可被清算成交 |
| 去杠杆 | `traders/P1Deleveraging.sol` | 穿仓/水下账户对盈方减仓（类 ADL） |
| 终局结算 | `impl/P1FinalSettlement.sol` | 市场关闭后的最终处理 |

插件化关键接口：`I_P1Trader.trade(...) → TradeResult{marginAmount, positionAmount, isBuy, flags}`。  
只有登记为 **global operator** 的 trader 合约能被 `trade()` 调用。

---

## 3. 一笔 `trade()` 在干什么（最重要）

```text
1. 校验 accounts 已排序且唯一
2. _loadContext()：读预言机价；按时间推进全局 funding Index
3. _settleAccounts()：对本批账户把 funding 落到 margin（懒结算）
4. 按序执行每笔 TradeArg：
     - 调 I_P1Trader(trader).trade(...)
     - 按结果改 maker/taker 的 margin 与 position（记账，不是订单簿）
5. _verifyAccountsFinalBalances()：
     - 要么最终足抵押
     - 要么仓位绝对值未增大、未翻面、抵押率未变差（允许「变好的减仓」）
```

含义：

- **链下撮合 / 链上结算**：真正改账在 `trade()`；订单合法性在 `P1Orders` 里验签。
- **批次**：一次 `trade` 可含多账户、多笔成交 —— 与我们 Spot `settleTrades` / 计划中的 perps 批次同构。
- **资金费**：不单独「转账列表」，而是 **Index 累积 + 动账户时结算**（算力友好，可借鉴；是否采用另定）。

---

## 4. 和我们需求的对照

| 点 | dYdX V1 | 我们（当前设计） |
|----|---------|------------------|
| 撮合 | 链下签单 + 链上 `trade` | 链下撮合 + 链上结算（同思路） |
| 仓位 | **链上** Balance.position | **待决 A1**（可不上链） |
| 保证金 | 链上 Balance.margin | 需要金库/余额（待决 B） |
| 预言机价 | 链上读，用于抵押率 | MCR 链下；若仓位不上链，链上可不读价 |
| 资金费 | Index 懒结算 | 待决 D1 |
| 清算 | `P1Liquidation` trader | 要，形态待定 |
| ADL/去杠杆 | `P1Deleveraging` | 待决 D2 |
| **PP / Claim / MCR** | **无**（经典足额保证金模型） | **有** —— 这是我们相对 V1 的产品增量 |
| 保险基金 | 无独立 PP 叙事 | 清算注入 → PP |
| Solidity | 0.5.16 | **0.8.28** |
| ZK | 无 | 已放弃 |

结论：**结算骨架（批次 trade、operator、订单 trader、清算/去杠杆插件）很值得参考；PP/Claim/FIFO 兑付要我们新写，不能从 V1 直接搬。**

---

## 5. 写 0.8.28 时建议「借鉴 / 不要照搬」

**可借鉴**

1. `trade(accounts, ops[])` 批处理形状  
2. `I_P1Trader` 式插件：Orders / Liquidation / Deleveraging 分离  
3. 全局 operator 白名单（≈ Spot `AllowedKeys`）  
4. 成交前先 settle funding（若资金费上链）  
5. 终态抵押率校验的「允许减仓改善、禁止恶化」思路（若仓位上链）  
6. `Balance` 用带符号的 margin/position 打包（若仓位上链）

**不要照搬**

1. 0.5.16 / SafeMath / experimental ABIEncoderV2（0.8 内置）  
2. 假设「有仓就有足额保证金、无 Claim」——与我们 PP 模型冲突  
3. 盈利平仓默认从对手盘 margin 同步划转即「拿满」——我们要插 **PP + Claim**  
4. 整份代理存储布局与 Admin 体系（可简化成 Ownable + 结算键）  
5. Maker/Chainlink 具体预言机接法（等我们定 A1/A4 再选）

---

## 6. 对我们 DEV 问题的暗示（非决定）

若希望「逻辑上跟 dYdX 差不多」：

- **A1** 更偏向 **仓位上链（B）**，才真正像 V1  
- **A2** 更偏向 **operator + 订单验签（A）**  
- **A4** 若仓位+预言机上链，可链上算盈亏；若跟现设计「引擎提交 C」，则偏离 V1、更靠近 Spot  
- **PP/Claim** 仍是 V1 没有的层，无论 A1 选哪边都要新设计

最终以 [`DEV_OPEN_QUESTIONS.md`](./DEV_OPEN_QUESTIONS.md) 你的书面解答为准。

---

## 7. 与本仓库当前主路径（2026-08）

本仓库已决：**系统账户 S + 强平接仓 + 触线 ADL**（无 Claim/MCR）。

| | dYdX V1 | 本仓库 |
|--|---------|--------|
| 强平接仓 | 外部清算人（taker） | **系统账户 S** |
| 缓冲 | 无独立保险基金（LiquidatorProxy 可抽成进保险地址） | **S 现金 = 缓冲** |
| 尾部 | Deleveraging | **ADL（触线）** |
| 仓位 | 链上 Balance | 链上（同方向） |

可借鉴：`trade` 批次、Orders/Liquidation/Deleveraging 插件分离、operator 白名单。  
接仓方与兑付缓冲合并进 S，是相对 V1 的产品简化（更靠近 CEX 保险基金叙事）。

---

## 8. 关键文件速查

```text
contracts/protocol/v1/PerpetualV1.sol
contracts/protocol/v1/impl/P1Trade.sol
contracts/protocol/v1/impl/P1Settlement.sol
contracts/protocol/v1/impl/P1Margin.sol
contracts/protocol/v1/lib/P1Types.sol
contracts/protocol/v1/lib/P1BalanceMath.sol
contracts/protocol/v1/traders/P1Orders.sol
contracts/protocol/v1/traders/P1Liquidation.sol
contracts/protocol/v1/traders/P1Deleveraging.sol
contracts/protocol/v1/intf/I_P1Trader.sol
```
