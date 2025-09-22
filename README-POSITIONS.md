# POSITIONS.csv Format Guide

## 📋 **Required CSV Format**

The `positions-factory.ts` script expects a CSV file with exactly these 5 columns:

```csv
wallet,amount,duration,transferable,forfeitable
0x1234567890123456789012345678901234567890,1000000000000000000000,31536000,true,false
```

## 🔢 **Column Details**

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `wallet` | string | Ethereum wallet address | `0x1234567890123456789012345678901234567890` |
| `amount` | string | Amount in **wei** (not HEMI tokens) | `1000000000000000000000` (1000 HEMI) |
| `duration` | string | Lock duration in **seconds** | `31536000` (1 year) |
| `transferable` | string | Whether NFT is transferable | `"true"` or `"false"` |
| `forfeitable` | string | Whether position can be forfeited | `"true"` or `"false"` |

## 🚀 **Quick Start**

### **Run Position Creation**
```bash
# For local testing
NODE_ENV=local npm run positions:create

# For production (set POSITION_FACTORY_ADDRESS first)
npm run positions:create
```

## 📊 **Format Examples**

### **Amount Format (Wei)**
| HEMI Tokens | Wei Amount |
|-------------|------------|
| 1 HEMI | `1000000000000000000` |
| 100 HEMI | `100000000000000000000` |
| 1000 HEMI | `1000000000000000000000` |
| 10000 HEMI | `10000000000000000000000` |

### **Duration Format (Seconds)**
| Duration | Seconds |
|----------|---------|
| 1 day | `86400` |
| 1 week | `604800` |
| 1 month | `2628000` |
| 6 months | `15768000` |
| 1 year | `31536000` |
| 2 years | `63072000` |
| 3 years | `94608000` |
| 4 years | `126144000` |

## 📝 **Example CSV**

```csv
wallet,amount,duration,transferable,forfeitable
0x1234567890123456789012345678901234567890,1000000000000000000000,31536000,true,false
0x2345678901234567890123456789012345678901,2000000000000000000000,63072000,true,false
0x3456789012345678901234567890123456789012,5000000000000000000000,94608000,false,true
0x4567890123456789012345678901234567890123,10000000000000000000000,126144000,true,false
0x5678901234567890123456789012345678901234,15000000000000000000000,157680000,true,false
```

## ⚠️ **Important Notes**

1. **Amounts in Wei**: The script expects amounts in wei, not HEMI tokens
2. **Duration in Seconds**: Use seconds, not days or years
3. **Boolean as Strings**: Use `"true"`/`"false"` strings, not boolean values
4. **No Header Row**: The script expects data rows, not headers
5. **Valid Addresses**: All wallet addresses must be valid Ethereum addresses

## 🧪 **Local Testing**

For local testing with Anvil:

```bash
# Start Anvil with fork
anvil --fork-url https://rpc.hemi.network/rpc --block-time 1

# Set environment variable
export NODE_ENV=local

# Run the script
npm run positions:create
```

## 🔄 **Script Workflow**

The `positions-factory.ts` script will:

1. **Read CSV** file (`POSITIONS.csv`)
2. **Whitelist** all positions (set status to PENDING)
3. **Approve** HEMI tokens to PositionFactory
4. **Create** each position individually
5. **Remove** the approval after completion

## 🚨 **Common Mistakes**

1. **Wrong Amount Format**: Using `1000` instead of `1000000000000000000000`
2. **Wrong Duration Format**: Using `365` instead of `31536000`
3. **Invalid Addresses**: Non-valid Ethereum addresses
4. **Wrong Column Order**: Columns must be in exact order
5. **Boolean Format**: Using `true` instead of `"true"`

## 💡 **Best Practices**

1. **Test with small batches** first
2. **Validate addresses** before running
3. **Keep backups** of your CSV files
4. **Use consistent formatting** throughout

## 🎯 **Ready to Use**

The `POSITIONS.csv` file is now ready to use with the `positions-factory.ts` script! 🎉
