import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-etherscan'
import '@nomiclabs/hardhat-waffle'
import '@typechain/hardhat'
import 'hardhat-contract-sizer'
import { HardhatUserConfig } from 'hardhat/config'
import { SolcUserConfig } from 'hardhat/types'
import 'solidity-coverage'

const { UNIWAP_PRIVATE_KEY } = process.env;
const accounts = UNIWAP_PRIVATE_KEY ? [UNIWAP_PRIVATE_KEY] : [];

const DEFAULT_COMPILER_SETTINGS: SolcUserConfig = {
  version: '0.7.6',
  settings: {
    optimizer: {
      enabled: true,
      runs: 200,
    },
    metadata: {
      bytecodeHash: 'none',
    },
  },
}

if (process.env.RUN_COVERAGE == '1') {
  /**
   * Updates the default compiler settings when running coverage.
   *
   * See https://github.com/sc-forks/solidity-coverage/issues/417#issuecomment-730526466
   */
  console.info('Using coverage compiler settings')
  DEFAULT_COMPILER_SETTINGS.settings.details = {
    yul: true,
    yulDetails: {
      stackAllocation: true,
    },
  }
}

const config: HardhatUserConfig = {
  networks: {
    hardhat: {
      allowUnlimitedContractSize: false,
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    ropsten: {
      url: `https://ropsten.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    kovan: {
      url: `https://kovan.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    arbitrumRinkeby: {
      url: `https://arbitrum-rinkeby.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    arbitrum: {
      url: `https://arbitrum-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    optimismKovan: {
      url: `https://optimism-kovan.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    optimism: {
      url: `https://optimism-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    mumbai: {
      url: `https://polygon-mumbai.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    polygon: {
      url: `https://polygon-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
    },
    wanMainnet: {
      chainId: 888,
      url: "https://gwan-ssl.wandevs.org:56891",
      accounts:accounts,
      gasPrice: 2_000_000_000,
    },
    wanTestnet: {
      chainId: 999,
      url: "https://gwan-ssl.wandevs.org:46891",
      accounts:accounts,
      gasPrice: 2_000_000_000,
     },
  },
  solidity: {
    compilers: [DEFAULT_COMPILER_SETTINGS],
  },
  contractSizer: {
    alphaSort: false,
    disambiguatePaths: true,
    runOnCompile: false,
  },
}

;(config as any).etherscan = {
  enabled: false,
  // Your API key for Etherscan
  // Obtain one at https://etherscan.io/
  apiKey: process.env.ETHERSCAN_API_KEY || 'NO_API_KEY_REQUIRED',
  // customChains: [
  //   {
  //     network: 'wanMainnet',
  //     chainId: 888,
  //     urls: {
  //       apiURL: 'https://wanscan.org/api',
  //       browserURL: 'https://wanscan.org',
  //     },
  //   },
  //   {
  //     network: 'wanTestnet',
  //     chainId: 999,
  //     urls: {
  //       apiURL: 'https://testnet.wanscan.org/api',
  //       browserURL: 'https://testnet.wanscan.org',
  //     },
  //   },
  // ],
}

;(config as any).sourcify = {
  // 设置为 true 进行验证
  enabled: true,
  // 可选：自定义 Sourcify 服务器
  // apiUrl: "https://sourcify.dev/server",
  // browserUrl: "https://repo.sourcify.dev",
  // runOnCompile: false,  // 不在编译时自动验证
  // forceProxies: true,   // 强制验证代理合约
}

export default config
