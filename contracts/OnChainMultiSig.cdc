import Crypto

pub contract OnChainMultiSig {
    
    pub event NewPayloadAdded(resourceId: UInt64, txIndex: UInt64);
    pub event NewPayloadSigAdded(resourceId: UInt64, txIndex: UInt64);

    /// Argument for payload
    pub struct PayloadArg {
        pub let type: Type;
        pub let value: AnyStruct;
        
        init(t: Type, v: AnyStruct) {
            self.type = t;
            self.value = v
        }
    }

    pub struct PayloadDetails {
        pub var method: String;
        pub var args: [PayloadArg];
        
        init(method: String, args: [PayloadArg]) {
            self.method = method;
            self.args = args;
        }

    }

    pub struct PubKeyAttr{
        pub let sigAlgo: UInt8;
        pub let weight: UFix64
        
        init(sa: UInt8, w: UFix64) {
            self.sigAlgo = sa;
            self.weight = w;
        }
    }
    
    pub struct PayloadSigDetails {
        pub var keyListSignatures: [Crypto.KeyListSignature];
        pub var pubKeys: [String];

        init(keyListSignatures: [Crypto.KeyListSignature], pubKeys: [String]){
            self.keyListSignatures = keyListSignatures;
            self.pubKeys = pubKeys 
        }
    }

    pub resource interface PublicSigner {
        // the first [UInt8] in the signable data will be the method
        // follow by the args if args are not resources
        pub fun UUID(): UInt64; 
        pub var signatureStore: SignatureStore;
        pub fun addNewPayload(payload: PayloadDetails, publicKey: String, sig: [UInt8]);
        pub fun addPayloadSignature (txIndex: UInt64, publicKey: String, sig: [UInt8]);
        pub fun executeTx(txIndex: UInt64): @AnyResource?;
    }
    
    pub struct interface SignatureManager {
        pub fun getSignableData(payload: PayloadDetails): [UInt8];
        pub fun addNewPayload (resourceId: UInt64, payload: PayloadDetails, publicKey: String, sig: [UInt8]): SignatureStore;
        pub fun addPayloadSignature (resourceId: UInt64, txIndex: UInt64, publicKey: String, sig: [UInt8]): SignatureStore;
        pub fun readyForExecution(txIndex: UInt64): PayloadDetails?;
    }

    pub struct SignatureStore {
        // Transaction index
        pub(set) var txIndex: UInt64;

        // Signers and their weights
        // String in hex to be decoded as [UInt8], without "0x" prefix
        pub let keyList: {String: PubKeyAttr};

        // map of an assigned index and the payload
        // payload in this case is the script and argument
        pub var payloads: {UInt64: PayloadDetails}

        pub var payloadSigs: {UInt64: PayloadSigDetails}

        init(publicKeys: [String], pubKeyAttrs: [PubKeyAttr]){
            assert( publicKeys.length == pubKeyAttrs.length, message: "pubkeys must have associated attributes")
            self.payloads = {};
            self.payloadSigs = {};
            self.keyList = {};
            self.txIndex = 0;
            
            var i: Int = 0;
            while (i < publicKeys.length){
                self.keyList.insert(key: publicKeys[i], pubKeyAttrs[i]);
                i = i + 1;
            }
        }
    }

    pub struct Manager: SignatureManager {
        
        pub var signatureStore: SignatureStore;

        pub fun getSignableData(payload: PayloadDetails): [UInt8] {
            var s = payload.method.utf8;
            for a in payload.args {
                var b: [UInt8] = [];
                switch a.type {
                    case Type<String>():
                        let temp = a.value as? String;
                        b = temp!.utf8; 
                    case Type<UInt64>():
                        let temp = a.value as? UInt64;
                        b = temp!.toBigEndianBytes(); 
                    case Type<UFix64>():
                        let temp = a.value as? UFix64;
                        b = temp!.toBigEndianBytes(); 
                    case Type<Address>():
                        let temp = a.value as? Address;
                        b = temp!.toBytes(); 
                    default:
                        panic ("Payload arg type not supported")
                }
                s = s.concat(b);
            }
            return s; 
        }
        
        // Currently not supporting MultiSig
        pub fun configureKeys (pks: [String], kws: [UFix64]): SignatureStore {
            var i: Int =  0;
            while (i < pks.length) {
                let a = PubKeyAttr(sa: 1, w: kws[i])
                self.signatureStore.keyList.insert(key: pks[i], a)
                i = i + 1;
            }

            return self.signatureStore
        }

        // Currently not supporting MultiSig
        pub fun removeKeys (pks: [String], kws: [UFix64]): SignatureStore {
            // TODO
            return self.signatureStore
        }
        
        pub fun addNewPayload (resourceId: UInt64, payload: PayloadDetails, publicKey: String, sig: [UInt8]): SignatureStore {
            assert(self.signatureStore.keyList.containsKey(publicKey), message: "Public key is not a registered signer");

            // The keyIndex is also 0 for the first key
            let keyListSig = [Crypto.KeyListSignature(keyIndex: 0, signature: sig)]

            // check if the payloadSig is signed by one of the account's keys, preventing others from adding to storage
            let approvalWeight = self.verifySigners(payload: payload, txIndex: nil, pks: [publicKey], sigs: keyListSig)
            if ( approvalWeight == nil) {
                panic ("invalid signer")
            }

            let txIndex = self.signatureStore.txIndex.saturatingAdd(1);
            self.signatureStore.txIndex = txIndex;
            assert(!self.signatureStore.payloads.containsKey(txIndex), message: "Payload index already exist");

            self.signatureStore.payloads.insert(key: txIndex, payload);

            let payloadSigDetails = PayloadSigDetails(
                    keyListSignatures: keyListSig,
                    pubKeys: [publicKey]
                )
            
            self.signatureStore.payloadSigs.insert(
                key: txIndex, 
                payloadSigDetails 
            )
            
            emit NewPayloadAdded(resourceId: resourceId, txIndex: txIndex)
            return self.signatureStore
        }

        pub fun addPayloadSignature (resourceId: UInt64, txIndex: UInt64, publicKey: String, sig: [UInt8]): SignatureStore {
            assert(self.signatureStore.payloads.containsKey(txIndex), message: "Payload has not been added");
            assert(self.signatureStore.keyList.containsKey(publicKey), message: "Public key is not a registered signer");

            // This is a temp keyListSig list that is used to verify a single signature so we use keyIndex as 0
            // The correct keyIndex will overwrite the 0 after we know it is a valid signature
            var keyListSig = Crypto.KeyListSignature( keyIndex: 0, signature: sig)

            // check if the payloadSig is signed by one of the account's keys, preventing others from adding to storage
            let approvalWeight = self.verifySigners(payload: nil, txIndex: txIndex, pks: [publicKey], sigs: [keyListSig])
            if ( approvalWeight == nil) {
                panic ("invalid signer")
            }

            let currentIndex = self.signatureStore.payloadSigs[txIndex]!.keyListSignatures.length
            keyListSig = Crypto.KeyListSignature(keyIndex: currentIndex, signature: sig)
            self.signatureStore.payloadSigs[txIndex]!.keyListSignatures.append(keyListSig);
            self.signatureStore.payloadSigs[txIndex]!.pubKeys.append(publicKey);

            emit NewPayloadSigAdded(resourceId: resourceId, txIndex: txIndex)
            return self.signatureStore
        }

        pub fun readyForExecution(txIndex: UInt64): PayloadDetails? {
            assert(self.signatureStore.payloads.containsKey(txIndex), message: "No payload for such index");
            let pks = self.signatureStore.payloadSigs[txIndex]!.pubKeys;
            let sigs = self.signatureStore.payloadSigs[txIndex]!.keyListSignatures;
            let approvalWeight = self.verifySigners(payload: nil, txIndex: txIndex, pks: pks, sigs: sigs)
            if (approvalWeight == nil) {
                return nil
            }
            if (approvalWeight! >= 1000.0) {
                self.signatureStore.payloadSigs.remove(key: txIndex)!;
                let pd = self.signatureStore.payloads.remove(key: txIndex)!;
                return pd;
            } else {
                return nil;
            }
        }
        
        pub fun verifySigners (payload: PayloadDetails?, txIndex: UInt64?, pks: [String], sigs: [Crypto.KeyListSignature]): UFix64? {
            assert(payload != nil || txIndex != nil, message: "cannot verify signature without payload or txIndex");
            assert(!(payload != nil && txIndex != nil), message: "cannot verify signature without payload or txIndex");
            assert(pks.length == sigs.length, message: "cannot verify signatures without corresponding public keys");
            
            var totalAuthorisedWeight: UFix64 = 0.0;
            var keyList = Crypto.KeyList();
            var payloadInBytes: [UInt8] = []
            if (payload != nil) {
                payloadInBytes = self.getSignableData(payload: payload!);
            } else {
                let p = self.signatureStore.payloads[txIndex!];
                payloadInBytes = self.getSignableData(payload: p!);
            }

            var i = 0;
            while (i < pks.length) {
                // Check if the public key is a registered signer
                if (self.signatureStore.keyList[pks[i]] == nil){
                    continue;
                }

                let pk = PublicKey(
                    publicKey: pks[i].decodeHex(),
                    signatureAlgorithm: SignatureAlgorithm(rawValue: self.signatureStore.keyList[pks[i]]!.sigAlgo) ?? panic ("invalid signature algo")
                )
                
                keyList.add(
                    pk, 
                    hashAlgorithm: HashAlgorithm.SHA3_256,
                    weight: self.signatureStore.keyList[pks[i]]!.weight
                )
                totalAuthorisedWeight = totalAuthorisedWeight + self.signatureStore.keyList[pks[i]]!.weight
                i = i + 1;
            }
            
            let isValid = keyList.verify(
                signatureSet: sigs,
                signedData: payloadInBytes,
            )
            if (isValid) {
                return totalAuthorisedWeight
            } else {
                return nil
            }
            
        }
        
        
        init(sigStore: SignatureStore) {
            self.signatureStore = sigStore;
        }
            
    }
}