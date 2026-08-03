import type { Address, WalletClient } from "viem";

const orderTypes = {
  Order: [
    { name: "trader", type: "address" },
    { name: "marketId", type: "uint256" },
    { name: "amount", type: "uint256" },
    { name: "priceX18", type: "uint256" },
    { name: "isBuy", type: "bool" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
} as const;

export type PerpsOrderMessage = {
  trader: Address;
  marketId: bigint;
  amount: bigint;
  priceX18: bigint;
  isBuy: boolean;
  nonce: bigint;
  expiry: bigint;
};

export async function signPerpsOrder(
  signer: WalletClient,
  chainId: number,
  verifyingContract: Address,
  order: PerpsOrderMessage,
): Promise<`0x${string}`> {
  return signer.signTypedData({
    domain: {
      name: "PerpsExchange",
      version: "1",
      chainId,
      verifyingContract,
    },
    types: orderTypes,
    primaryType: "Order",
    message: order,
  });
}

const withdrawTypes = {
  Withdraw: [
    { name: "user", type: "address" },
    { name: "orderId", type: "uint256" },
    { name: "amount", type: "uint256" },
  ],
} as const;

export async function signPerpsWithdraw(
  signer: WalletClient,
  chainId: number,
  verifyingContract: Address,
  message: { user: Address; orderId: bigint; amount: bigint },
): Promise<`0x${string}`> {
  return signer.signTypedData({
    domain: {
      name: "GlobalPerpsVault",
      version: "1",
      chainId,
      verifyingContract,
    },
    types: withdrawTypes,
    primaryType: "Withdraw",
    message,
  });
}
