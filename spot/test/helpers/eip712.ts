import type { Address, WalletClient } from "viem";
import { encodeAbiParameters, keccak256 } from "viem";

import { SPOT_EIP712_NAME, SPOT_EIP712_VERSION } from "./fixture.js";

const spotOrderTypes = {
  SpotOrder: [
    { name: "maker", type: "address" },
    { name: "makerToken", type: "address" },
    { name: "takerToken", type: "address" },
    { name: "makerAmount", type: "uint256" },
    { name: "takerAmount", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "salt", type: "uint256" },
  ],
} as const;

export type SpotOrderMessage = {
  maker: Address;
  makerToken: Address;
  takerToken: Address;
  makerAmount: bigint;
  takerAmount: bigint;
  expiry: bigint;
  salt: bigint;
};

/// @dev Matches `SpotExchange._hashOrder` (`abi.encode` of struct fields, then `keccak256`).
export function hashSpotOrderStruct(
  spotOrderTypehash: `0x${string}`,
  order: SpotOrderMessage,
): `0x${string}` {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [
        spotOrderTypehash,
        order.maker,
        order.makerToken,
        order.takerToken,
        order.makerAmount,
        order.takerAmount,
        order.expiry,
        order.salt,
      ],
    ),
  );
}

export async function signSpotOrder(
  signer: WalletClient,
  chainId: number,
  verifyingContract: Address,
  order: SpotOrderMessage,
): Promise<`0x${string}`> {
  const signature = await signer.signTypedData({
    domain: {
      name: SPOT_EIP712_NAME,
      version: SPOT_EIP712_VERSION,
      chainId,
      verifyingContract,
    },
    types: spotOrderTypes,
    primaryType: "SpotOrder",
    message: order,
  });
  return signature;
}

const withdrawTypes = {
  Withdraw: [
    { name: "orderId", type: "uint256" },
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

export async function signWithdraw(
  signer: WalletClient,
  chainId: number,
  verifyingContract: Address,
  message: { orderId: bigint; token: Address; amount: bigint },
): Promise<`0x${string}`> {
  return signer.signTypedData({
    domain: {
      name: "GlobalSpotVault",
      version: "1",
      chainId,
      verifyingContract,
    },
    types: withdrawTypes,
    primaryType: "Withdraw",
    message,
  });
}
