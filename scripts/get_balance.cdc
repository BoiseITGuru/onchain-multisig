// This script reads the balance field of an account's FlowToken Balance

import FungibleToken from 0x{{.FungibleToken}}
import MultiSigFlowToken from 0x{{.MultiSigFlowToken}}

pub fun main(account: Address): UFix64 {
    let acct = getAccount(account)
    let vaultRef = acct.getCapability(MultiSigFlowToken.VaultBalancePubPath)
        .borrow<&MultiSigFlowToken.Vault{FungibleToken.Balance}>()
        ?? panic("Could not borrow Balance reference to the Vault")

    return vaultRef.balance
}
