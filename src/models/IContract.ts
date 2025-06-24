import Contract from "../utils/Contract";
import _ from "lodash";
import axios from "axios";
// @ts-ignore
import PolkamarketsSmartAccount from "./PolkamarketsSmartAccount";
import { ethers } from "ethers";
import { IContractParams } from "../types/contracts";

// Permissionless and thirdweb imports (use any for now)
const {
  ENTRYPOINT_ADDRESS_V06,
  bundlerActions,
  providerToSmartAccountSigner,
  getAccountNonce,
} = require("permissionless");
const {
  pimlicoBundlerActions,
  pimlicoPaymasterActions,
} = require("permissionless/actions/pimlico");
const { createClient, createPublicClient, http } = require("viem");
const { signerToSimpleSmartAccount } = require("permissionless/accounts");
const {
  getPaymasterAndData,
  estimateUserOpGas,
  bundleUserOp,
  signUserOp,
  waitForUserOpReceipt,
  getUserOpGasFees,
  createUnsignedUserOp,
} = require("thirdweb/wallets/smart");
const {
  createThirdwebClient,
  getContract: getThirdwebContract,
  prepareContractCall,
  prepareTransaction,
  sendTransaction,
  waitForReceipt,
} = require("thirdweb");
const { defineChain } = require("thirdweb/chains");
const { ethers5Adapter } = require("thirdweb/adapters/ethers5");
const { smartWallet } = require("thirdweb/wallets/smart");

class IContract {
  web3: any;
  acc?: any;
  params: any;
  contractName: string = '';

  constructor({
    web3,
    contractAddress = null,
    abi,
    acc,
    web3EventsProvider,
    gasPrice,
    isSocialLogin = false,
    startBlock,
  }: IContractParams) {
    if (!abi) {
      throw new Error("No ABI Interface provided");
    }
    if (!web3) {
      throw new Error("Please provide a valid web3 provider");
    }

    this.web3 = web3;

    if (acc) {
      this.acc = acc;
    }

    this.params = {
      web3,
      abi,
      contractAddress,
      web3EventsProvider,
      gasPrice,
      contract: new Contract(web3, abi, contractAddress || ""),
      isSocialLogin,
      startBlock,
    };
  }

  async __init__() {
    if (!this.getAddress()) {
      throw new Error("Please add a Contract Address");
    }
    await this.__assert();
  }

  async __metamaskCall({ f, acc, value, callback = () => {} }: any) {
    return new Promise((resolve, reject) => {
      f
        .send({
          from: acc,
          value: value,
          gasPrice: this.params.gasPrice,
          maxPriorityFeePerGas: null,
          maxFeePerGas: null,
        })
        .on("confirmation", (confirmationNumber: number, receipt: any) => {
          callback(confirmationNumber);
          if (confirmationNumber > 0) {
            resolve(receipt);
          }
        })
        .on("error", (err: any) => {
          reject(err);
        });
    });
  }

  waitForTransactionHashToBeGenerated(userOpHash: string, networkConfig: any) {
    return new Promise((resolve, reject) => {
      const interval = setInterval(async () => {
        try {
          const userOperation = await axios.post(
            `${networkConfig.bundlerRPC}/rpc?chainId=${networkConfig.chainId}`,
            {
              method: "eth_getUserOperationByHash",
              params: [userOpHash],
            },
          );

          if (
            userOperation.data.result &&
            userOperation.data.result.transactionHash
          ) {
            clearInterval(interval);
            resolve(userOperation.data.result.transactionHash);
          } else if (networkConfig.bundlerAPI) {
            let userOperationData;
            try {
              userOperationData = await axios.get(
                `${networkConfig.bundlerAPI}/user_operations/${userOpHash}`,
              );
            } catch (error) {
              // fetch should be non-blocking
            }

            if (
              userOperationData &&
              userOperationData.data &&
              userOperationData.data.status === "failed"
            ) {
              clearInterval(interval);
              reject(new Error("User operation failed"));
            }
          }
        } catch (error) {
          // non-blocking
        }
      }, 1000);
    });
  }

  operationDataFromCall(f: any) {
    return {
      contract: this.params.abi.contractName,
      method: f._method.name,
      arguments: f.arguments,
    };
  }

  getUserOpHash(chainId: any, userOp: any, entryPoint: any) {
    const abiCoder = new ethers.utils.AbiCoder();
    const userOpHash = ethers.utils.keccak256(this.packUserOp(userOp, true));
    const enc = abiCoder.encode(
      ["bytes32", "address", "uint256"],
      [userOpHash, entryPoint, chainId],
    );
    return ethers.utils.keccak256(enc);
  }

  packUserOp(userOp: any, forSignature = true) {
    const abiCoder = new ethers.utils.AbiCoder();
    if (forSignature) {
      return abiCoder.encode(
        [
          "address",
          "uint256",
          "bytes32",
          "bytes32",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "bytes32",
        ],
        [
          userOp.sender,
          userOp.nonce,
          ethers.utils.keccak256(userOp.initCode),
          ethers.utils.keccak256(userOp.callData),
          userOp.callGasLimit,
          userOp.verificationGasLimit,
          userOp.preVerificationGas,
          userOp.maxFeePerGas,
          userOp.maxPriorityFeePerGas,
          ethers.utils.keccak256(userOp.paymasterAndData),
        ],
      );
    } else {
      return abiCoder.encode(
        [
          "address",
          "uint256",
          "bytes",
          "bytes",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "bytes",
          "bytes",
        ],
        [
          userOp.sender,
          userOp.nonce,
          userOp.initCode,
          userOp.callData,
          userOp.callGasLimit,
          userOp.verificationGasLimit,
          userOp.preVerificationGas,
          userOp.maxFeePerGas,
          userOp.maxPriorityFeePerGas,
          userOp.paymasterAndData,
          userOp.signature,
        ],
      );
    }
  }

  waitForTransactionHashToBeGeneratedPimlico(
    userOpHash: string,
    pimlicoBundlerClient: any,
  ) {
    return new Promise((resolve, reject) => {
      const interval = setInterval(async () => {
        try {
          const getStatusResult =
            await pimlicoBundlerClient.getUserOperationStatus({
              hash: userOpHash,
            });

          if (getStatusResult.status === "failed") {
            clearInterval(interval);
            reject(new Error(`User operation failed: ${getStatusResult.transactionHash}`));
          }

          if (getStatusResult.transactionHash) {
            clearInterval(interval);
            resolve(getStatusResult.transactionHash);
          }
        } catch (error) {
          // non-blocking
        }
      }, 1000);
    });
  }

  async usePimlicoForGaslessTransactions(
    f: any,
    tx: any,
    methodCallData: any,
    networkConfig: any,
    provider: any,
  ) {
    const publicClient = createPublicClient({
      chain: networkConfig.viemChain,
      transport: http(networkConfig.rpcUrl),
    });

    const bundlerClient = createClient({
      chain: networkConfig.viemChain,
      transport: http(networkConfig.bundlerRPC),
    })
      .extend(bundlerActions)
      .extend(pimlicoBundlerActions);

    const paymasterClient = createClient({
      chain: networkConfig.viemChain,
      transport: http(networkConfig.paymasterRPC),
    }).extend(pimlicoPaymasterActions);

    const smartAccountSigner = await providerToSmartAccountSigner(provider);
    const factoryAddress = networkConfig.factoryAddress || PolkamarketsSmartAccount.PIMLICO_FACTORY_ADDRESS;

    const smartAccount = await signerToSimpleSmartAccount(publicClient, {
      signer: smartAccountSigner,
      factoryAddress: factoryAddress,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
    });

    const gasPrices = await bundlerClient.getUserOperationGasPrice();

    const userOperation: any = {
      sender: smartAccount.address,
      nonce: await getAccountNonce(publicClient, {
        sender: smartAccount.address,
        entryPoint: ENTRYPOINT_ADDRESS_V06,
      }),
      initCode: smartAccount.initCode,
      callData: smartAccount.encodeCallData(tx),
      maxFeePerGas: gasPrices.fast.maxFeePerGas,
      maxPriorityFeePerGas: gasPrices.fast.maxPriorityFeePerGas,
      signature: smartAccount.dummySignature,
    };

    const sponsorUserOperationResult = await paymasterClient.sponsorUserOperation({
      userOperation: userOperation,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
    });

    userOperation.preVerificationGas = sponsorUserOperationResult.preVerificationGas;
    userOperation.verificationGasLimit = sponsorUserOperationResult.verificationGasLimit;
    userOperation.callGasLimit = sponsorUserOperationResult.callGasLimit;
    userOperation.paymasterAndData = sponsorUserOperationResult.paymasterAndData;

    userOperation.signature = await smartAccount.signUserOperation(userOperation);

    const userOpHash = await bundlerClient.sendUserOperation({
      userOperation,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
    });

    return await this.waitForTransactionHashToBeGeneratedPimlico(
      userOpHash,
      bundlerClient,
    );
  }

  async useThirdWebForGaslessTransactions(
    f: any,
    tx: any,
    methodCallData: any,
    networkConfig: any,
    provider: any,
  ) {
    const client = createThirdwebClient({
      clientId: networkConfig.thirdwebClientId,
    });
    const chain = defineChain(networkConfig.chainId);
    const smartAccountSigner = await ethers5Adapter.fromSigner(provider.getSigner());
    const account = await smartWallet({
      chain,
      client,
      factoryAddress: networkConfig.factoryAddress || PolkamarketsSmartAccount.THIRDWEB_FACTORY_ADDRESS,
      gasless: true,
      personalAccount: smartAccountSigner,
    });
    const contract = getThirdwebContract({
      address: this.getAddress(),
      abi: this.params.abi.abi,
      client: client,
      chain: chain,
    });
    const { to, data, value } = await prepareContractCall({
      contract,
      method: f._method.name,
      params: methodCallData.arguments,
      value: tx.value ? ethers.utils.parseEther(tx.value) : undefined,
    });
    const transaction = await prepareTransaction({
      to: to,
      data: data,
      value: value,
      chain: chain,
      client: client,
    });
    const { transactionHash } = await account.sendTransaction(transaction);
    return transactionHash;
  }

  async useThirdWebForGaslessTransactionsWithThirdWebAuth(
    f: any,
    tx: any,
    methodCallData: any,
    networkConfig: any,
    provider: any,
  ) {
    const client = createThirdwebClient({
      clientId: networkConfig.thirdwebClientId,
    });
    const chain = defineChain(networkConfig.chainId);

    const contract = getThirdwebContract({
      address: this.getAddress(),
      abi: this.params.abi.abi,
      client: client,
      chain: chain,
    });
    const { to, data, value } = await prepareContractCall({
      contract,
      method: f._method.name,
      params: methodCallData.arguments,
      value: tx.value ? ethers.utils.parseEther(tx.value) : undefined,
    });
    const transaction = await prepareTransaction({
      to: to,
      data: data,
      value: value,
      chain: chain,
      client: client,
    });
    const { transactionHash } = await sendTransaction({
      account: provider.smartAccount,
      transaction,
    });
    return transactionHash;
  }

  async useThirdWebForGaslessWithZKSync(
    f: any,
    tx: any,
    methodCallData: any,
    networkConfig: any,
    provider: any,
  ) {
    if (provider.getNonce) {
      const nonce = await provider.getNonce("latest");
      tx.nonce = nonce;
    }
    tx.gasLimit = await provider.estimateGas(tx);

    const signedTx = await provider.signTransaction(tx);
    const { hash } = await provider.sendTransaction(signedTx);
    return hash;
  }

  async sendGaslessTransactions(f: any) {
    const polkamarketsSmartAccount =
      PolkamarketsSmartAccount.singleton.getInstanceIfExists();
    const networkConfig = polkamarketsSmartAccount
      ? polkamarketsSmartAccount.networkConfig
      : {};

    const tx = {
      from:
        (await this.getMyAccount()) ||
        (this.acc ? this.acc.address : undefined),
      to: this.getAddress(),
      data: f.encodeABI(),
    };
    const methodCallData = this.operationDataFromCall(f);

    if (networkConfig.useThirdWeb && networkConfig.isZkSync) {
      return this.useThirdWebForGaslessWithZKSync(
        f,
        tx,
        methodCallData,
        networkConfig,
        this.web3,
      );
    } else if (
      networkConfig.useThirdWeb &&
      polkamarketsSmartAccount.provider.adminAccount
    ) {
      return this.useThirdWebForGaslessTransactionsWithThirdWebAuth(
        f,
        tx,
        methodCallData,
        networkConfig,
        polkamarketsSmartAccount.provider,
      );
    } else if (networkConfig.useThirdWeb) {
      return this.useThirdWebForGaslessTransactions(
        f,
        tx,
        methodCallData,
        networkConfig,
        this.web3,
      );
    } else if (networkConfig.usePimlico) {
      return this.usePimlicoForGaslessTransactions(
        f,
        tx,
        methodCallData,
        networkConfig,
        this.web3,
      );
    }

    const { userOp, userOpHash } =
      await polkamarketsSmartAccount.smartAccount.buildUserOperation({ tx });
    const { receipt } =
      await polkamarketsSmartAccount.smartAccount.sendUserOperation({
        userOp,
        userOpHash,
      });
    return receipt;
  }

  convertEtherEventsToWeb3Events(events: any[]) {
    return events.map((event) => {
      const topics = event.topics.map((topic: string) => topic);
      return {
        ...event,
        raw: {
          topics,
          data: event.data,
        },
      };
    });
  }

  async __sendTx(
    f: any,
    privateKey?: string | boolean,
    value?: string,
    callback: (confirmationNumber: number) => void = () => {},
  ) {
    if (privateKey === true) {
      // is a call
      return await f.call();
    }
    const { web3, isSocialLogin } = this.params;

    if (isSocialLogin) {
      return this.sendGaslessTransactions(f);
    }

    const polkamarketsSmartAccount =
      PolkamarketsSmartAccount.singleton.getInstanceIfExists();
    const { isConnectedWallet } = polkamarketsSmartAccount
      ? await polkamarketsSmartAccount.providerIsConnectedWallet()
      : { isConnectedWallet: false };

    if (isConnectedWallet) {
      const tx = {
        to: this.getAddress(),
        data: f.encodeABI(),
        value,
      };
      const account = await this.getMyAccount();
      return this.__metamaskCall({ f, acc: account, value, callback });
    }

    const tx = {
      from:
        (await this.getMyAccount()) ||
        (this.acc ? this.acc.address : undefined),
      to: this.getAddress(),
      data: f.encodeABI(),
      value,
    };

    if (privateKey) {
      const signedTx = await this.web3.eth.accounts.signTransaction(
        tx,
        privateKey,
      );
      return this.web3.eth.sendSignedTransaction(signedTx.rawTransaction);
    }

    return this.web3.eth.sendTransaction(tx);
  }

  async __deploy(params: any[], callback: (txHash: string) => void) {
    return new Promise((resolve, reject) => {
      this.params.contract
        .deploy({
          data: this.params.abi.bytecode,
          arguments: params,
        })
        .send(
          {
            from: this.acc.address,
            gas: 5500000,
            gasPrice: this.params.gasPrice,
          },
          (err: any, txHash: string) => {
            if (err) {
              return reject(err);
            }
            if (callback) {
              callback(txHash);
            }
          },
        )
        .on("error", (err: any) => reject(err))
        .then((newContractInstance: any) => {
          this.params.contract.setContract(newContractInstance);
          this.params.contractAddress = newContractInstance.options.address;
          resolve(newContractInstance.options.address);
        });
    });
  }

  async __assert() {
    // virtual method
  }

  async deploy({ callback, params = [] }: { callback?: (txHash: string) => void; params?: any[] } = {}) {
    if (this.params.isSocialLogin) {
      throw new Error("Social login does not support deploy");
    }
    const myAccount = await this.getMyAccount();
    if (!myAccount) {
      throw new Error("Please connect your wallet");
    }
    this.acc = { address: myAccount };
    return await this.__deploy(params, callback || (() => {}));
  }

  async setNewOwner({ address }: { address: string }) {
    if (this.params.isSocialLogin) {
      throw new Error("Social login does not support setNewOwner");
    }
    const myAccount = await this.getMyAccount();
    if (!myAccount) {
      throw new Error("Please connect your wallet");
    }
    return await this.__sendTx(this.getContract().methods.transferOwnership(address));
  }

  async owner(): Promise<string> {
    return await this.getContract().methods.owner().call();
  }

  async isPaused(): Promise<boolean> {
    return await this.getContract().methods.paused().call();
  }

  async pauseContract() {
    return await this.__sendTx(this.getContract().methods.pause());
  }

  async unpauseContract() {
    return await this.__sendTx(this.getContract().methods.unpause());
  }

  async removeOtherERC20Tokens({ tokenAddress, toAddress }: { tokenAddress: string, toAddress: string }) {
    return await this.__sendTx(
      this.getContract().methods.removeOtherERC20Tokens(tokenAddress, toAddress)
    );
  }

  async safeGuardAllTokens({ toAddress }: { toAddress: string }) {
    return await this.__sendTx(
      this.getContract().methods.safeGuardAllTokens(toAddress)
    );
  }

  async changeTokenAddress({ newTokenAddress }: { newTokenAddress: string }) {
    return await this.__sendTx(
      this.getContract().methods.changeTokenAddress(newTokenAddress)
    );
  }

  getAddress(): string {
    return this.params.contractAddress;
  }

  getContract() {
    return this.params.contract.getContract();
  }

  async getBalance(): Promise<string> {
    const address = this.getAddress();
    if (!address) return "0";
    return this.web3.eth.getBalance(address);
  }

  async getMyAccount(): Promise<string | null> {
    const polkamarketsSmartAccount = PolkamarketsSmartAccount.singleton.getInstanceIfExists();
    if (polkamarketsSmartAccount && polkamarketsSmartAccount.provider) {
      return await polkamarketsSmartAccount.getAddress();
    }

    if (this.acc && this.acc.address) {
      return this.acc.address;
    } else {
      const accounts = await this.web3.eth.getAccounts();
      if (accounts.length > 0) {
        return accounts[0];
      }
    }
    return null;
  }

  async getEvents(event: string, filter: any = {}, fromBlock: any = null, toBlock: "latest" | number = "latest"): Promise<any[]> {
    const web3 = this.params.web3EventsProvider ? new this.web3(this.params.web3EventsProvider) : this.web3;
    const contract = new web3.eth.Contract(this.params.abi.abi, this.getAddress());
    return await contract.getPastEvents(event, {
      filter,
      fromBlock: fromBlock || this.params.startBlock,
      toBlock: toBlock,
    });
  }

  async getBlock(blockNumber: number | string) {
    return await this.web3.eth.getBlock(blockNumber);
  }
}

export default IContract;
