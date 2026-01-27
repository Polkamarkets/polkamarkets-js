const Contract = require("../utils/Contract");
const _ = require("lodash");
const axios = require('axios');
const PolkamarketsSmartAccount = require('./PolkamarketsSmartAccount');
const ethers = require('ethers').ethers;

const { ENTRYPOINT_ADDRESS_V06, bundlerActions, providerToSmartAccountSigner, getAccountNonce } = require('permissionless');
const { pimlicoBundlerActions, pimlicoPaymasterActions } = require('permissionless/actions/pimlico');
const { createClient, createPublicClient, http } = require('viem');
const { signerToSimpleSmartAccount } = require('permissionless/accounts');

const { getPaymasterAndData, estimateUserOpGas, bundleUserOp, signUserOp, waitForUserOpReceipt, getUserOpGasFees, createUnsignedUserOp } = require('thirdweb/wallets/smart');
const { createThirdwebClient, getContract, prepareContractCall, prepareTransaction, sendTransaction, waitForReceipt } = require('thirdweb');
const { defineChain } = require('thirdweb/chains');
const { ethers5Adapter } = require('thirdweb/adapters/ethers5');
const { smartWallet } = require('thirdweb/wallets/smart');

/**
 * Contract Object Interface
 * @constructor IContract
 * @param {Web3} web3
 * @param {Address} contractAddress ? (opt)
 * @param {ABI} abi
 * @param {Account} acc ? (opt)
 */


class IContract {
  constructor({
    web3,
    contractAddress = null /* If not deployed */,
    abi,
    acc,
    web3EventsProvider,
    gasPrice,
    isSocialLogin = false,
    useGaslessTransactions,
    startBlock
  }) {
    try {
      if (!abi) {
        throw new Error("No ABI Interface provided");
      }
      if (!web3) {
        throw new Error("Please provide a valid web3 provider");
      };

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
        contract: new Contract(web3, abi, contractAddress),
        isSocialLogin,
        // (For backwards compatibility) If useGaslessTransactions is not explicitly set, default to true when isSocialLogin is true, otherwise false
        useGaslessTransactions: useGaslessTransactions !== undefined ? useGaslessTransactions : isSocialLogin,
        startBlock,
      };
    } catch (err) {
      throw err;
    }
  }

  async __init__() {
    try {
      if (!this.getAddress()) {
        throw new Error("Please add a Contract Address");
      }

      await this.__assert();
    } catch (err) {
      throw err;
    }
  };

  async __metamaskCall({ f, acc, value, callback = () => { } }) {
    return f.send({
      from: acc,
      value: value,
      gasPrice: this.params.gasPrice,
      maxPriorityFeePerGas: null,
      maxFeePerGas: null
    })
      .on("confirmation", (confirmationNumber, receipt) => {
        callback(confirmationNumber)
        if (confirmationNumber > 0) {
          resolve(receipt);
        }
      })
      .on("error", (err) => {
        throw err;
        // reject(err);
      });
  };

  waitForTransactionHashToBeGenerated(userOpHash, networkConfig) {
    return new Promise((resolve, reject) => {
      const interval = setInterval(async () => {
        const userOperation = await axios.post(`${networkConfig.bundlerRPC}/rpc?chainId=${networkConfig.chainId}`,
          {
            "method": "eth_getUserOperationByHash",
            "params": [
              userOpHash
            ]
          }
        );

        if (userOperation.data.result && userOperation.data.result.transactionHash) {
          clearInterval(interval);
          resolve(userOperation.data.result.transactionHash);
        } else if (networkConfig.bundlerAPI) {
          let userOperationData;
          try {
            userOperationData = await axios.get(`${networkConfig.bundlerAPI}/user_operations/${userOpHash}`);
          } catch (error) {
            // fetch should be non-blocking
          }

          if (userOperationData && userOperationData.data && userOperationData.data.status === 'failed') {
            clearInterval(interval);
            reject(new Error('User operation failed'));
          }
        }
      }, 1000);
    });
  }

  operationDataFromCall(f) {
    return {
      contract: this.params.abi.contractName,
      method: f._method.name,
      arguments: f.arguments,
    };
  }

  getUserOpHash(chainId, userOp, entryPoint) {
    const abiCoder = new ethers.utils.AbiCoder();

    const userOpHash = ethers.utils.keccak256(this.packUserOp(userOp, true));
    const enc = abiCoder.encode(['bytes32', 'address', 'uint256'], [userOpHash, entryPoint, chainId]);
    return ethers.utils.keccak256(enc);
  }

  packUserOp(userOp, forSignature = true) {
    const abiCoder = new ethers.utils.AbiCoder();
    if (forSignature) {
      return abiCoder.encode(
        ['address', 'uint256', 'bytes32', 'bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'bytes32'],
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
      // for the purpose of calculating gas cost encode also signature (and no keccak of bytes)
      return abiCoder.encode(
        ['address', 'uint256', 'bytes', 'bytes', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'bytes', 'bytes'],
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

  waitForTransactionHashToBeGeneratedPimlico(userOpHash, pimlicoBundlerClient) {
    return new Promise((resolve, reject) => {
      const interval = setInterval(async () => {
        const getStatusResult = await pimlicoBundlerClient.getUserOperationStatus({
          hash: userOpHash,
        })

        if (getStatusResult.transactionHash) {
          clearInterval(interval);
          resolve(getStatusResult.transactionHash);
        }
      }, 1000);
    });
  }

  async usePimlicoForGaslessTransactions(f, tx, methodCallData, networkConfig, provider) {
    const accountABI = ["function execute(address to, uint256 value, bytes data)"];
    const account = new ethers.utils.Interface(accountABI);
    const callData = account.encodeFunctionData("execute", [
      tx.to,
      ethers.constants.Zero,
      methodCallData,
    ]);

    const publicClient = createPublicClient({
      chain: networkConfig.viemChain,
      transport: http(networkConfig.rpcUrl)
    });

    const bundlerClient = createClient({
      transport: http(`${networkConfig.pimlicoUrl}/${networkConfig.chainId}/rpc?apikey=${networkConfig.pimlicoApiKey}`),
      chain: networkConfig.viemChain,
    })
      .extend(bundlerActions(ENTRYPOINT_ADDRESS_V06))
      .extend(pimlicoBundlerActions(ENTRYPOINT_ADDRESS_V06))


    const paymasterClient = createClient({
      transport: http(`${networkConfig.pimlicoUrl}/${networkConfig.chainId}/rpc?apikey=${networkConfig.pimlicoApiKey}`),
      chain: networkConfig.viemChain,
    }).extend(pimlicoPaymasterActions(ENTRYPOINT_ADDRESS_V06))

    const smartAccountSigner = await providerToSmartAccountSigner(provider);

    const smartAccount = await signerToSimpleSmartAccount(publicClient, {
      signer: smartAccountSigner,
      factoryAddress: networkConfig.factoryAddress || PolkamarketsSmartAccount.PIMLICO_FACTORY_ADDRESS,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
    })

    const initCode = await smartAccount.getInitCode();
    const senderAddress = smartAccount.address;

    const gasPrice = await bundlerClient.getUserOperationGasPrice()

    const key = BigInt(Math.floor(Math.random() * 6277101735386680763835789423207666416102355444464034512895));

    const nonce = await getAccountNonce(publicClient, {
      sender: senderAddress,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
      key
    })

    const userOperation = {
      sender: senderAddress,
      nonce,
      initCode: initCode,
      callData: callData,
      maxFeePerGas: Number(gasPrice.fast.maxFeePerGas),
      maxPriorityFeePerGas: Number(gasPrice.fast.maxPriorityFeePerGas),
      signature: await smartAccount.getDummySignature(),
    }

    const sponsorUserOperationResult = await paymasterClient.sponsorUserOperation({
      userOperation,
    })

    const sponsoredUserOperation = {
      ...userOperation,
      ...sponsorUserOperationResult,
    }

    const signature = await smartAccount.signUserOperation(sponsoredUserOperation);

    sponsoredUserOperation.signature = signature;

    let userOpHash = this.getUserOpHash(networkConfig.chainId, sponsoredUserOperation, ENTRYPOINT_ADDRESS_V06);

    if (networkConfig.bundlerAPI) {
      sponsoredUserOperation.nonce = ethers.BigNumber.from(sponsoredUserOperation.nonce).toHexString();
      sponsoredUserOperation.maxFeePerGas = ethers.BigNumber.from(sponsoredUserOperation.maxFeePerGas).toHexString();
      sponsoredUserOperation.maxPriorityFeePerGas = ethers.BigNumber.from(sponsoredUserOperation.maxPriorityFeePerGas).toHexString();
      sponsoredUserOperation.preVerificationGas = ethers.BigNumber.from(sponsoredUserOperation.preVerificationGas).toHexString();
      sponsoredUserOperation.verificationGasLimit = ethers.BigNumber.from(sponsoredUserOperation.verificationGasLimit).toHexString();
      sponsoredUserOperation.callGasLimit = ethers.BigNumber.from(sponsoredUserOperation.callGasLimit).toHexString();

      const txResponse = await axios.post(`${networkConfig.bundlerAPI}/user_operations`,
        {
          user_operation: {
            user_operation: sponsoredUserOperation,
            user_operation_hash: userOpHash,
            user_operation_data: [this.operationDataFromCall(f)],
            network_id: networkConfig.chainId,
          }
        }
      );

      if (txResponse.data.error) {
        throw new Error(txResponse.data.error.message);
      }
    } else {
      userOpHash = await bundlerClient.sendUserOperation({
        userOperation: sponsoredUserOperation,
      })
    }

    const transactionHash = await this.waitForTransactionHashToBeGeneratedPimlico(userOpHash, bundlerClient);

    const receipt = await publicClient.waitForTransactionReceipt(
      { hash: transactionHash }
    )

    return receipt;

  }

  async useThirdWebForGaslessTransactions(f, tx, methodCallData, networkConfig, provider) {
    const accountABI = ["function execute(address to, uint256 value, bytes data)"];
    const account = new ethers.utils.Interface(accountABI);
    const callData = account.encodeFunctionData("execute", [
      tx.to,
      ethers.constants.Zero,
      methodCallData,
    ]);

    const publicClient = createPublicClient({
      chain: networkConfig.viemChain,
      transport: http(networkConfig.rpcUrl)
    });

    const smartAccountSigner = await providerToSmartAccountSigner(provider);

    const smartAccount = await signerToSimpleSmartAccount(publicClient, {
      signer: smartAccountSigner,
      factoryAddress: networkConfig.factoryAddress || PolkamarketsSmartAccount.PIMLICO_FACTORY_ADDRESS,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
    })

    const initCode = await smartAccount.getInitCode();
    const senderAddress = smartAccount.address;

    const client = createThirdwebClient({ clientId: networkConfig.thirdWebClientId });

    const chain = defineChain(networkConfig.chainId);

    const gasPrice = await getUserOpGasFees(
      {
        options: {
          entrypointAddress: ENTRYPOINT_ADDRESS_V06,
          chain,
          client,
        }
      }
    );

    const key = BigInt(Math.floor(Math.random() * 6277101735386680763835789423207666416102355444464034512895));

    const nonce = await getAccountNonce(publicClient, {
      sender: senderAddress,
      entryPoint: ENTRYPOINT_ADDRESS_V06,
      key
    })

    const userOperation = {
      sender: senderAddress,
      nonce,
      initCode: initCode,
      callData: callData,
      maxFeePerGas: Number(gasPrice.maxFeePerGas),
      maxPriorityFeePerGas: Number(gasPrice.maxPriorityFeePerGas),
      signature: await smartAccount.getDummySignature(),
      paymasterAndData: '0x',
    }

    const gasFees = await estimateUserOpGas({
      userOp: userOperation,
      options: {
        entrypointAddress: ENTRYPOINT_ADDRESS_V06,
        chain,
        client,
      }
    })

    userOperation.verificationGasLimit = gasFees.verificationGasLimit;
    userOperation.preVerificationGas = gasFees.preVerificationGas;
    userOperation.callGasLimit = gasFees.callGasLimit;

    const sponsorUserOperationResult = await getPaymasterAndData(
      {
        userOp: userOperation,
        client,
        chain,
        entrypointAddress: ENTRYPOINT_ADDRESS_V06,
      }
    );

    userOperation.paymasterAndData = sponsorUserOperationResult.paymasterAndData;

    if (
      sponsorUserOperationResult.callGasLimit &&
      sponsorUserOperationResult.verificationGasLimit &&
      sponsorUserOperationResult.preVerificationGas
    ) {
      userOperation.callGasLimit = sponsorUserOperationResult.callGasLimit;
      userOperation.verificationGasLimit = sponsorUserOperationResult.verificationGasLimit;
      userOperation.preVerificationGas = sponsorUserOperationResult.preVerificationGas;
    }

    const signedUserOp = await signUserOp({
      userOp: userOperation,
      chain,
      client,
      entrypointAddress: ENTRYPOINT_ADDRESS_V06,
      adminAccount: smartAccountSigner,
    });

    let userOpHash = this.getUserOpHash(networkConfig.chainId, signedUserOp, ENTRYPOINT_ADDRESS_V06);

    if (networkConfig.bundlerAPI) {
      userOperation.nonce = ethers.BigNumber.from(userOperation.nonce).toHexString();
      userOperation.maxFeePerGas = ethers.BigNumber.from(userOperation.maxFeePerGas).toHexString();
      userOperation.maxPriorityFeePerGas = ethers.BigNumber.from(userOperation.maxPriorityFeePerGas).toHexString();
      userOperation.preVerificationGas = ethers.BigNumber.from(userOperation.preVerificationGas).toHexString();
      userOperation.verificationGasLimit = ethers.BigNumber.from(userOperation.verificationGasLimit).toHexString();
      userOperation.callGasLimit = ethers.BigNumber.from(userOperation.callGasLimit).toHexString();
      userOperation.signature = signedUserOp.signature;

      // currently txs are not bundled in thirdweb
      axios.post(`${networkConfig.bundlerAPI}/user_operations`,
        {
          user_operation: {
            user_operation: userOperation,
            user_operation_hash: userOpHash,
            user_operation_data: [this.operationDataFromCall(f)],
            network_id: networkConfig.chainId,
          },
          do_not_bundle: true
        }
      );
    }

    userOpHash = await bundleUserOp({
      userOp: signedUserOp,
      options: {
        entrypointAddress: ENTRYPOINT_ADDRESS_V06,
        chain,
        client,
      }
    })

    const receipt = await waitForUserOpReceipt({
      chain,
      client,
      userOpHash,
    });

    return receipt;
  }

  async useThirdWebForGaslessTransactionsWithThirdWebAuth(f, tx, methodCallData, networkConfig, provider) {

    const client = createThirdwebClient({ clientId: networkConfig.thirdWebClientId });

    const chain = defineChain(networkConfig.chainId);

    const factoryContract = getContract({
      client: client,
      address: networkConfig.factoryAddress || PolkamarketsSmartAccount.THIRDWEB_FACTORY_ADDRESS,
      chain: chain,
    });

    const accountContract = getContract({
      client,
      address: provider.smartAccount.address,
      chain,
    });

    const transaction = prepareContractCall({
      contract: accountContract,
      method: "function execute(address, uint256, bytes)",
      params: [
        tx.to,
        0n,
        tx.data,
      ],
    });

    const userOperation = await createUnsignedUserOp({
      transaction,
      factoryContract,
      accountContract,
      adminAddress: provider.adminAccount.address,
      sponsorGas: true,
    });

    const signedUserOp = await signUserOp({
      userOp: userOperation,
      chain,
      client,
      entrypointAddress: ENTRYPOINT_ADDRESS_V06,
      adminAccount: provider.adminAccount,
    });

    let userOpHash = this.getUserOpHash(networkConfig.chainId, signedUserOp, ENTRYPOINT_ADDRESS_V06);

    if (networkConfig.bundlerAPI) {
      userOperation.nonce = ethers.BigNumber.from(userOperation.nonce).toHexString();
      userOperation.maxFeePerGas = ethers.BigNumber.from(userOperation.maxFeePerGas).toHexString();
      userOperation.maxPriorityFeePerGas = ethers.BigNumber.from(userOperation.maxPriorityFeePerGas).toHexString();
      userOperation.preVerificationGas = ethers.BigNumber.from(userOperation.preVerificationGas).toHexString();
      userOperation.verificationGasLimit = ethers.BigNumber.from(userOperation.verificationGasLimit).toHexString();
      userOperation.callGasLimit = ethers.BigNumber.from(userOperation.callGasLimit).toHexString();
      userOperation.signature = signedUserOp.signature;

      // currently txs are not bundled in thirdweb
      axios.post(`${networkConfig.bundlerAPI}/user_operations`,
        {
          user_operation: {
            user_operation: userOperation,
            user_operation_hash: userOpHash,
            user_operation_data: [this.operationDataFromCall(f)],
            network_id: networkConfig.chainId,
          },
          do_not_bundle: true
        }
      );
    }

    userOpHash = await bundleUserOp({
      userOp: signedUserOp,
      options: {
        entrypointAddress: ENTRYPOINT_ADDRESS_V06,
        chain,
        client,
      }
    })

    const receipt = await waitForUserOpReceipt({
      chain,
      client,
      userOpHash,
    });

    return receipt;
  }

  async useThirdWebForGaslessWithZKSync(f, tx, methodCallData, networkConfig, provider) {

    const client = createThirdwebClient({ clientId: networkConfig.thirdWebClientId });
    const chain = defineChain(networkConfig.chainId);
    let smartAccount;

    if (provider.address) {
      // it's already a thirdweb smart account
      smartAccount = provider;
    } else if (provider.smartAccount) {
      smartAccount = provider.smartAccount;
    } else {
      const wallet = smartWallet({
        chain,
        sponsorGas: true, // enable sponsored transactions
      });

      let personalAccount = provider.personalAccount
      if (!provider.personalAccount) {
        const signer = provider.getSigner();
        personalAccount = await ethers5Adapter.signer.fromEthers({ signer });
      }

      smartAccount = await wallet.connect({
        client,
        personalAccount,
      });
    }

    const transaction = prepareTransaction({
      chain,
      client,
      to: tx.to,
      data: tx.data
    });

    const res = await sendTransaction({
      transaction,
      account: smartAccount,
    });

    const receipt = await waitForReceipt({
      client,
      chain,
      transactionHash: res.transactionHash,
    });

    return receipt;
  }

  async useThirdWebWithUserPaidGas(tx, networkConfig, smartAccount) {
    const client = createThirdwebClient({ clientId: networkConfig.thirdWebClientId });
    const chain = defineChain(networkConfig.chainId);

    if (!smartAccount || typeof smartAccount.sendTransaction !== 'function') {
      throw new Error('Invalid account provided - expected thirdweb Account object with sendTransaction method');
    }

    const res = await smartAccount.sendTransaction({
      to: tx.to,
      data: tx.data,
      gas: BigInt(500000),
      chain: chain,
    });

    const receipt = await waitForReceipt({
      client,
      chain,
      transactionHash: res.transactionHash,
    });

    return receipt;
  }

  async sendGaslessTransactions(f) {
    const smartAccount = PolkamarketsSmartAccount.singleton.getInstance();
    const networkConfig = smartAccount.networkConfig;

    const { isConnectedWallet, signer } = await smartAccount.providerIsConnectedWallet();

    const methodName = f._method.name;

    const contractInterface = new ethers.utils.Interface(this.params.abi.abi);
    const methodCallData = contractInterface.encodeFunctionData(methodName, f.arguments);

    const tx = {
      to: this.params.contractAddress,
      data: methodCallData,
    };

    try {
      let receipt;

      if (isConnectedWallet) {
        const txResponse = await signer.sendTransaction({ ...tx, gasLimit: 210000 });
        receipt = await txResponse.wait();
      } else {

        if (networkConfig.usePimlico) {
          receipt = await this.usePimlicoForGaslessTransactions(f, tx, methodCallData, networkConfig, smartAccount.provider);
        } else if (networkConfig.useThirdWeb) {
          if (networkConfig.isZkSync) {
            receipt = await this.useThirdWebForGaslessWithZKSync(f, tx, methodCallData, networkConfig, smartAccount.provider);
          } else if (smartAccount.provider.adminAccount) {
            // if exists adminAccount it means it's using thirdwebauth
            receipt = await this.useThirdWebForGaslessTransactionsWithThirdWebAuth(f, tx, methodCallData, networkConfig, smartAccount.provider);
          } else {
            receipt = await this.useThirdWebForGaslessTransactions(f, tx, methodCallData, networkConfig, smartAccount.provider);
          }
        } else {
          // trying operation 3 times
          const retries = 3;
          let feeQuotesResult;
          for (let i = 0; i < retries; i++) {
            try {
              feeQuotesResult = await smartAccount.smartAccount.getFeeQuotes(tx);
              break;
            } catch (error) {
              await new Promise((resolve) => setTimeout(resolve, 5000));

              if (i === retries - 1) {
                throw error;
              } else {
                // 1s interval between retries
                await new Promise((resolve) => setTimeout(resolve, 1000));
              }
            }
          }

          let userOp = feeQuotesResult.verifyingPaymasterGasless.userOp;
          let userOpHash = feeQuotesResult.verifyingPaymasterGasless.userOpHash;

          // Get random key
          const key = BigInt(Math.floor(Math.random() * 6277101735386680763835789423207666416102355444464034512895));

          const entrypointAbi = [
            "function getNonce(address sender, uint192 key) view returns (uint256)",
          ];

          const ethersProvider = new ethers.providers.JsonRpcProvider(this.params.web3.currentProvider.host);

          const entrypointContract = new ethers.Contract(ENTRYPOINT_ADDRESS_V06, entrypointAbi, ethersProvider);

          const senderAddress = await smartAccount.getAddress();

          const nonce = await entrypointContract.getNonce(senderAddress, key);

          userOp.nonce = nonce.toHexString();


          const paymasterSponsorData = await axios.post(`https://paymaster.particle.network`,
            {

              "method": "pm_sponsorUserOperation",
              "params": [
                userOp,
                ENTRYPOINT_ADDRESS_V06,
              ]
            }, {
            params: {
              chainId: networkConfig.chainId,
              projectUuid: networkConfig.particleProjectId,
              projectKey: networkConfig.particleClientKey,
            }
          }
          );


          userOp.paymasterAndData = paymasterSponsorData.data.result.paymasterAndData;

          userOpHash = this.getUserOpHash(networkConfig.chainId, userOp, ENTRYPOINT_ADDRESS_V06);

          const signedUserOp = await smartAccount.smartAccount.signUserOperation({ userOpHash, userOp });

          let txResponse;
          for (let i = 0; i < retries; i++) {
            try {
              if (networkConfig.bundlerAPI) {
                txResponse = await axios.post(`${networkConfig.bundlerAPI}/user_operations`,
                  {
                    user_operation: {
                      user_operation: signedUserOp,
                      user_operation_hash: userOpHash,
                      user_operation_data: [this.operationDataFromCall(f)],
                      network_id: networkConfig.chainId,
                    }
                  }
                );
              } else {
                txResponse = await axios.post(`${networkConfig.bundlerRPC}/rpc?chainId=${networkConfig.chainId}`,
                  {

                    "method": "eth_sendUserOperation",
                    "params": [
                      signedUserOp,
                      ENTRYPOINT_ADDRESS_V06
                    ]
                  }
                );
              }

              if (!txResponse.data.error) break;
            } catch (error) {
              if (i === retries - 1) {
                throw error;
              } else {
                // 1s interval between retries
                await new Promise((resolve) => setTimeout(resolve, 1000));
              }
            }
          }

          if (txResponse.data.error) {
            throw new Error(txResponse.data.error.message);
          }

          const transactionHash = await this.waitForTransactionHashToBeGenerated(userOpHash, networkConfig);

          const web3Provider = new ethers.providers.Web3Provider(smartAccount.provider)

          receipt = await web3Provider.waitForTransaction(transactionHash);
        }

        console.log('receipt:', receipt.status, receipt.transactionHash);
      }

      if (receipt.logs) {
        const events = receipt.logs.map(log => {
          try {
            const event = contractInterface.parseLog(log);
            return event;
          } catch (error) {
            return null;
          }
        });
        receipt.events = this.convertEtherEventsToWeb3Events(events);
      }

      return receipt;
    } catch (error) {
      console.error(error);
      throw error;
    }
  }

  convertEtherEventsToWeb3Events(events) {
    const transformedEvents = {};
    for (const event of events) {
      if (!event) {
        continue;
      }

      const { name, args, eventFragment } = event;

      const returnValues = {};

      eventFragment.inputs.forEach((input, index) => {
        let value = args[index];

        // if value is a BigNumber, convert it to a string
        if (ethers.BigNumber.isBigNumber(value)) {
          value = value.toString();
        }

        returnValues[input.name] = value;
        returnValues[index.toString()] = value;
      });

      const transformedEvent = {
        event: name,
        returnValues,
      };

      if (!transformedEvents[name]) {
        transformedEvents[name] = [];
      }

      transformedEvents[name].push(transformedEvent);
    }

    return transformedEvents;
  }

  async sendSocialLoginGasTransactions(f) {
    const smartAccount = PolkamarketsSmartAccount.singleton.getInstance();
    const networkConfig = smartAccount.networkConfig;

    const { isConnectedWallet, signer } = await smartAccount.providerIsConnectedWallet();

    const methodName = f._method.name;

    const contractInterface = new ethers.utils.Interface(this.params.abi.abi);
    const methodCallData = contractInterface.encodeFunctionData(methodName, f.arguments);

    const tx = {
      to: this.params.contractAddress,
      data: methodCallData,
    };

    try {
      let receipt;

      if (isConnectedWallet) {
        const txResponse = await signer.sendTransaction({ ...tx, gasLimit: 210000 });
        receipt = await txResponse.wait();
      } else {
        if (networkConfig.useThirdWeb) {
          const thirdwebAccount = smartAccount.getThirdwebAccount();
          if (!thirdwebAccount) {
            throw new Error('ThirdWeb account not found. Make sure you passed the thirdweb account when calling login()');
          }
          receipt = await this.useThirdWebWithUserPaidGas(tx, networkConfig, thirdwebAccount);
        } else {
          throw new Error('User-paid transactions are only supported with ThirdWeb configuration');
        }
      }

      console.log('receipt:', receipt.status, receipt.transactionHash);

      if (receipt.logs) {
        const events = receipt.logs.map(log => {
          try {
            const event = contractInterface.parseLog(log);
            return event;
          } catch (error) {
            return null;
          }
        });
        receipt.events = this.convertEtherEventsToWeb3Events(events);
      }

      return receipt;
    } catch (error) {
      console.error(error);
      throw error;
    }
  }

  async __sendTx(f, call = false, value, callback = () => { }) {
    if (this.params.isSocialLogin && !call) {
      if (this.params.useGaslessTransactions) {
        return await this.sendGaslessTransactions(f);
      } else {
        return await this.sendSocialLoginGasTransactions(f);
      }
    } else {
      var res;
      if (!this.acc && !call) {
        const accounts = await this.params.web3.eth.getAccounts();
        res = await this.__metamaskCall({ f, acc: accounts[0], value, callback });
      } else if (this.acc && !call) {
        let data = f.encodeABI();
        res = await this.params.contract.send(
          this.acc.getAccount(),
          data,
          value
        ).catch(err => { throw err; });
      } else if (this.acc && call) {
        res = await f.call({ from: this.acc.getAddress() }).catch(err => { throw err; });
      } else {
        res = await f.call().catch(err => { throw err; });
      }

      if (res.logs) {
        const contractInterface = new ethers.utils.Interface(this.params.abi.abi);

        const events = res.logs.map(log => {
          try {
            const event = contractInterface.parseLog(log);
            return event;
          } catch (error) {
            return null;
          }
        });

        res.events = this.convertEtherEventsToWeb3Events(events);
      }

      return res;
    }
  };

  async __deploy(params, callback) {
    return await this.params.contract.deploy(
      this.acc,
      this.params.contract.getABI(),
      this.params.contract.getJSON().bytecode,
      params,
      callback
    );
  };

  async __assert() {
    if (!this.getAddress()) {
      throw new Error("Contract is not deployed, first deploy it and provide a contract address");
    }
    /* Use ABI */
    this.params.contract.use(this.params.abi, this.getAddress());
  }

  /**
   * @function deploy
   * @description Deploy the Contract
  */
  async deploy({ callback, params = [] }) {
    let res = await this.__deploy(params, callback);
    this.params.contractAddress = res.contractAddress;
    /* Call to Backend API */
    await this.__assert();
    return res;
  };


  /**
   * @function setNewOwner
   * @description Set New Owner of the Contract
   * @param {string} address
   */
  async setNewOwner({ address }) {
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.transferOwnership(address)
    );
  }

  /**
   * @function owner
   * @description Get Owner of the Contract
   * @returns {string} address
   */

  async owner() {
    return await this.params.contract.getContract().methods.owner().call();
  }

  /**
   * @function isPaused
   * @description Get Owner of the Contract
   * @returns {boolean}
   */

  async isPaused() {
    return await this.params.contract.getContract().methods.paused().call();
  }

  /**
   * @function pauseContract
   * @type admin
   * @description Pause Contract
   */
  async pauseContract() {
    return await this.__sendTx(
      this.params.contract.getContract().methods.pause()
    );
  }

  /**
   * @function unpauseContract
   * @type admin
   * @description Unpause Contract
   */
  async unpauseContract() {
    return await this.__sendTx(
      this.params.contract.getContract().methods.unpause()
    );
  }

  /* Optional */

  /**
   * @function removeOtherERC20Tokens
   * @description Remove Tokens from other ERC20 Address (in case of accident)
   * @param {Address} tokenAddress
   * @param {Address} toAddress
   */
  async removeOtherERC20Tokens({ tokenAddress, toAddress }) {
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.removeOtherERC20Tokens(tokenAddress, toAddress)
    );
  };

  /**
   * @function safeGuardAllTokens
   * @description Remove all tokens for the sake of bug or problem in the smart contract, contract has to be paused first, only Admin
   * @param {Address} toAddress
   */
  async safeGuardAllTokens({ toAddress }) {
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.safeGuardAllTokens(toAddress)
    );
  };

  /**
   * @function changeTokenAddress
   * @description Change Token Address of Application
   * @param {Address} newTokenAddress
   */
  async changeTokenAddress({ newTokenAddress }) {
    return await this.__sendTx(
      this.params.contract
        .getContract()
        .methods.changeTokenAddress(newTokenAddress)
    );
  };

  /**
   * @function getAddress
   * @description Get Balance of Contract
   * @param {Integer} Balance
   */
  getAddress() {
    return this.params.contractAddress;
  }

  /**
   * @function getContract
   * @description Gets Contract
   * @return {Contract} Contract
   */
  getContract() {
    return this.params.contract.getContract();
  }

  /**
   * @function getBalance
   * @description Get Balance of Contract
   * @param {Integer} Balance
   */

  async getBalance() {
    let wei = await this.web3.eth.getBalance(this.getAddress());
    return this.web3.utils.fromWei(wei, 'ether');
  };

  /**
   * @function getMyAccount
   * @description Returns connected wallet account address
   * @returns {String | undefined} address
   */
  async getMyAccount() {
    if (this.params.isSocialLogin) {
      const smartAccount = PolkamarketsSmartAccount.singleton.getInstance();
      return await smartAccount.getAddress();
    }

    if (this.acc) {
      return this.acc.getAddress()
    }

    const accounts = await this.params.web3.eth.getAccounts();

    return accounts[0];
  }

  /**
   * @function getEvents
   * @description Gets contract events
   * @returns {String | undefined} address
   */
  async getEvents(event, filter, fromBlock = null, toBlock = 'latest') {
    if (!fromBlock) {
      fromBlock = this.params.startBlock || 0;
    }

    if (!this.params.web3EventsProvider) {
      const events = this.getContract().getPastEvents(event, {
        fromBlock,
        toBlock,
        filter
      });

      return events;
    }

    // getting events via http from web3 events provide
    let uri = `${this.params.web3EventsProvider}/events?contract=${this.contractName}&address=${this.getAddress()}&eventName=${event}`
    if (filter) uri = uri.concat(`&filter=${JSON.stringify(filter)}`);

    const { data } = await axios.get(uri);
    return data;
  }

  /**
   * @function getBlock
   * @description Gets block details
   * @returns {Object} block
   */
  async getBlock(blockNumber) {
    return await this.params.web3.eth.getBlock(blockNumber);
  }
}

module.exports = IContract;
