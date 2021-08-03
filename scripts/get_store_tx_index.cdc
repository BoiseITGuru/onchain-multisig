// This script reads the balance field of an account's FiatToken Balance

import FungibleToken from 0x{{.FungibleToken}}
import OnChainMultiSig from 0x{{.OnChainMultiSig}}
import MultiSigFlowToken from 0x{{.MultiSigFlowToken}}

pub fun main(account: Address): UInt64{
    let acct = getAccount(account)
    let vaultRef = acct.getCapability(MultiSigFlowToken.VaultPubSigner)
        .borrow<&MultiSigFlowToken.Vault{OnChainMultiSig.PublicSigner}>()
        ?? panic("Could not borrow Pub Signer reference to the Vault")

    return vaultRef.signatureStore!.txIndex
}
