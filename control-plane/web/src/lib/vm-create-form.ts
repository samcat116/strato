export interface VMNetworkInterfaceDraft {
  key: string;
  networkId: string;
  securityGroupIds: string[];
  mtu: string;
}

export function createNetworkInterfaceDraft(index = 0): VMNetworkInterfaceDraft {
  return {
    key: `nic-${index}`,
    networkId: "",
    securityGroupIds: [],
    mtu: "",
  };
}
