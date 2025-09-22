# POSITIONS.csv Format

## 📋 **Required Columns**

The `POSITIONS.csv` file must have exactly these 5 columns in this order:

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `wallet` | string | Ethereum wallet address | `0x1234567890123456789012345678901234567890` |
| `amount` | string | Amount in wei (not HEMI tokens) | `1000000000000000000000` (1000 HEMI) |
| `duration` | string | Lock duration in seconds | `31536000` (1 year) |
| `transferable` | string | Whether NFT is transferable | `true` or `false` |
| `forfeitable` | string | Whether position can be forfeited | `true` or `false` |

## 📝 **CSV Format Example**

```csv
wallet,amount,duration,transferable,forfeitable
0x1234567890123456789012345678901234567890,1000000000000000000000,31536000,true,false
0x2345678901234567890123456789012345678901,2000000000000000000000,63072000,true,false
0x3456789012345678901234567890123456789012,5000000000000000000000,94608000,false,true
```

## 🔢 **Amount Conversion**

**Important**: The `amount` field must be in **wei**, not HEMI tokens.

| HEMI Tokens | Wei Amount |
|-------------|------------|
| 1 HEMI | `1000000000000000000` |
| 100 HEMI | `100000000000000000000` |
| 1000 HEMI | `1000000000000000000000` |
| 10000 HEMI | `10000000000000000000000` |

## ⏰ **Duration Conversion**

The `duration` field must be in **seconds**.

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

## ✅ **Boolean Values**

- `transferable`: `"true"` or `"false"` (as strings)
- `forfeitable`: `"true"` or `"false"` (as strings)

## 🚨 **Important Notes**

1. **No Header Row**: The script expects the first row to be data, not headers
2. **Exact Column Order**: Columns must be in the exact order shown
3. **No Spaces**: Avoid spaces around values
4. **Valid Addresses**: All wallet addresses must be valid Ethereum addresses
5. **Wei Amounts**: Amounts must be in wei (multiply HEMI tokens by 10^18)

## 🧪 **Testing with Local Environment**

For local testing:

```bash
# Set environment variable for local testing
export NODE_ENV=local

# Run the script
npx ts-node scripts/positions-factory.ts
```

## 📊 **Example Data**

Here's a sample with different scenarios:

```csv
wallet,amount,duration,transferable,forfeitable
0x1234567890123456789012345678901234567890,1000000000000000000000,31536000,true,false
0x2345678901234567890123456789012345678901,2000000000000000000000,63072000,true,false
0x3456789012345678901234567890123456789012,5000000000000000000000,94608000,false,true
0x4567890123456789012345678901234567890123,10000000000000000000000,126144000,true,false
0x5678901234567890123456789012345678901234,15000000000000000000000,157680000,true,false
```

## 🔧 **Script Usage**

The script will:

1. **Whitelist** all positions (set status to PENDING)
2. **Approve** HEMI tokens to the PositionFactory
3. **Create** each position individually
4. **Remove** the approval after completion

## ⚠️ **Common Mistakes**

1. **Using HEMI tokens instead of wei**: `1000` instead of `1000000000000000000000`
2. **Wrong column order**: Make sure columns are in exact order
3. **Invalid addresses**: Ensure all wallet addresses are valid
4. **String vs boolean**: Use `"true"`/`"false"` strings, not boolean values
5. **Duration in wrong units**: Use seconds, not days or years

## 🎯 **Best Practices**

1. **Test with small batches** first
2. **Validate addresses** before running
3. **Check amounts** are in wei
4. **Use consistent formatting**
5. **Keep backups** of your CSV files
