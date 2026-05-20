import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";
import "hardhat-deploy";

const accounts: [string] | undefined = process.env.DEPLOYER_PRIVATE_KEY
    ? [process.env.DEPLOYER_PRIVATE_KEY!]
    : undefined;

// Optional fork config: when HEMI_RPC_URL is set, the default `hardhat`
// network forks Hemi mainnet at HEMI_FORK_BLOCK (or latest). Used by
// `test/hardhat/deploy-e2e.test.ts` to run the deploy script against
// real on-chain state. Unset HEMI_RPC_URL to fall back to the standard
// empty in-memory chain (preserves prior local-dev behavior).
const hardhatForking = process.env.HEMI_RPC_URL
    ? {
          forking: {
              url: process.env.HEMI_RPC_URL,
              blockNumber: process.env.HEMI_FORK_BLOCK
                  ? Number(process.env.HEMI_FORK_BLOCK)
                  : undefined,
          },
          chainId: 43111, // match Hemi so deploy scripts' chainId gate passes
          // Hemi targets Cancun from genesis. Without this, Hardhat throws
          // "No known hardfork for execution on historical block N" when
          // any contract call is dispatched to the EDR-VM at the fork
          // block.
          chains: {
              43111: {
                  hardforkHistory: {
                      cancun: 0,
                  },
              },
          },
      }
    : {};

const config: HardhatUserConfig = {
    defaultNetwork: "hardhat",
    networks: {
        hardhat: hardhatForking,
        localhost: {
            chainId: 31337,
            accounts,
            saveDeployments: true,
            autoImpersonate: true
        },
        hemi: {
            chainId: 43111,
            url: process.env.PROVIDER_URL || "",
            accounts
        }
    },
    etherscan: {
        enabled: true,
        apiKey: {
            hemi: "noApiKeyNeeded"
        },
        customChains: [
            {
                network: "hemi",
                chainId: 43111,
                urls: {
                    apiURL: "https://explorer.hemi.xyz/api",
                    browserURL: "https://explorer.hemi.xyz/"
                }
            }
        ]
    },
    solidity: {
        version: "0.8.29",
        settings: {
            optimizer: {
                enabled: true,
                runs: 1
            },
            evmVersion: "cancun"
        }
    },
    paths: {
        sources: "src",
        cache: "cache_hardhat"
    },
    // When the `hardhat` network is forked from Hemi mainnet
    // (HEMI_RPC_URL set), reuse the existing mainnet deployment artifacts
    // so deploy scripts treat VeHemi/VeHemiVoteDelegation/etc. as
    // already-deployed rather than trying to deploy fresh copies.
    // Enables `deployments.run(...)` against a fork in
    // `test/hardhat/deploy-e2e.test.ts`.
    external: process.env.HEMI_RPC_URL
        ? {
              deployments: {
                  hardhat: ["deployments/hemi"],
              },
          }
        : undefined,
    namedAccounts: {
        deployer: process.env.DEPLOYER || 0
    }
};

export default config;
