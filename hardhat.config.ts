import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";
import "hardhat-deploy";

const accounts: [string] | undefined = process.env.DEPLOYER_PRIVATE_KEY
    ? [process.env.DEPLOYER_PRIVATE_KEY!]
    : undefined;

const config: HardhatUserConfig = {
    defaultNetwork: "hardhat",
    networks: {
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
    namedAccounts: {
        deployer: process.env.DEPLOYER || 0
    }
};

export default config;
