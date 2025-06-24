// Contract artifact JSON structure
export interface ContractJSON {
  abi: any[];
  bytecode?: string;
  networks?: any;
  [key: string]: any;
}

// Mapping of contract names to their JSON artifacts
export interface ContractInterfaces {
  achievements: ContractJSON;
  arbitration: ContractJSON;
  arbitrationProxy: ContractJSON;
  fantasyerc20: ContractJSON;
  ierc20: ContractJSON;
  prediction: ContractJSON;
  predictionV2: ContractJSON;
  predictionV3: ContractJSON;
  predictionV3_2: ContractJSON;
  predictionV3Manager: ContractJSON;
  predictionV3Controller: ContractJSON;
  predictionMarketV3Factory: ContractJSON;
  predictionV3Querier: ContractJSON;
  realitio: ContractJSON;
  voting: ContractJSON;
  weth: ContractJSON;
}

// Parameters for contract constructors
export interface IContractParams {
  web3: any;
  contractAddress?: string | null;
  abi: any;
  acc?: any;
  web3EventsProvider?: any;
  gasPrice?: any;
  isSocialLogin?: boolean;
  startBlock?: any;
}

// ERC20 method argument types
export interface BalanceOfArgs {
  account: string;
}
export interface AllowanceArgs {
  owner: string;
  spender: string;
}
export interface ApproveArgs {
  spender: string;
  amount: number;
}
