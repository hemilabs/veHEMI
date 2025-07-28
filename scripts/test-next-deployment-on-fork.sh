#!/bin/bash

# Impersonate deployer
#npx hardhat impersonate-deployer --network localhost

# Prepare deployment data
#cp -r deployments/hemi deployments/localhost

# Deployment
npx hardhat deploy --network localhost

# Test next release
#npx hardhat test --network localhost test/E2E.$network.next.test.ts
