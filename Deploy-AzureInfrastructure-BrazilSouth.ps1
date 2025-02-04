param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$LocationBrazil,

    [Parameter(Mandatory = $true)]
    [string]$LocationUS,

    [Parameter(Mandatory = $true)]
    [string]$ClientNameUpper,

    [Parameter(Mandatory = $true)]
    [string]$ClientNameLower,

    [Parameter(Mandatory = $false)]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $false)]
    [string]$SecondVMName,

    [Parameter(Mandatory = $false)]
    [bool]$CriarSegundaVM = $false,

    [Parameter(Mandatory = $false)]
    [bool]$InstalarVPN = $false,

    [Parameter(Mandatory = $true)]
    [string]$VMUsername,

    [Parameter(Mandatory = $true)]
    [string]$VMPassword
)

# Função para exibir mensagens coloridas com suporte a negrito
function Write-Log {
    param (
        [string]$Message,
        [string]$Type
    )

    # Adicionar uma linha em branco antes de cada nova mensagem, exceto para o primeiro log
    if ($global:FirstLog -ne $true) {
        Write-Host ""
    } else {
        $global:FirstLog = $false
    }

    switch ($Type) {
        "INFO" { Write-Host $Message -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        "WARNING" { Write-Host $Message -ForegroundColor Yellow }
        "BOLD-YELLOW" { Write-Host "`e[1m$Message`e[0m" -ForegroundColor Yellow } # Negrito e amarelo
        default { Write-Host $Message }
    }
}
$global:FirstLog = $true

# Selecionar Assinatura do Azure
Write-Log "Selecionando a assinatura do Azure..." "INFO"
Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null
Write-Log "Assinatura selecionada com sucesso." "SUCCESS"
Write-Host ""
$subscription = Get-AzSubscription -SubscriptionId $SubscriptionId
$subscription | Format-Table -Property Name, Id, State, TenantId

# Função para criar Resource Group
function Create-ResourceGroup {
    param (
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$Technology
    )
    Write-Log "Criando Resource Group '$ResourceGroupName' na região '$Location'..." "INFO"
    $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tags @{"client"=$ClientNameLower; "environment"=$Environment; "technology"=$Technology}
    Write-Log "Resource Group '$ResourceGroupName' criado com sucesso." "SUCCESS"
    Write-Host ""
    $rg | Format-Table -Property ResourceGroupName, Location, ProvisioningState
}

# Criar Resource Groups
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-VM" -Location $LocationBrazil -Technology "vm"
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-Storage" -Location $LocationBrazil -Technology "storage"
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-Networks" -Location $LocationBrazil -Technology "network"
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-Backup" -Location $LocationBrazil -Technology "backup"
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-Automation" -Location $LocationUS -Technology "automationaccounts"
Create-ResourceGroup -ResourceGroupName "RG-$ClientNameUpper-LogAnalytics" -Location $LocationUS -Technology "loganalyticsworkspace"

# Função para criar VNET + Subnet + GatewaySubnet
function Create-VNet {
    param (
        [string]$ResourceGroupName,
        [string]$VNetName,
        [string]$AddressPrefix,
        [string]$Location
    )
    Write-Log "Criando VNet '$VNetName' no grupo de recursos '$ResourceGroupName'..." "INFO"
    $vnet = New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName -AddressPrefix $AddressPrefix -Location $Location -Tag @{"client"=$ClientNameLower; "environment"=$Environment; "technology"="network"}
    Write-Log "VNet '$VNetName' criada com sucesso." "SUCCESS"
    $vnet | Format-Table -Property Name, Location, ProvisioningState -AutoSize
}

function Add-Subnet {
    param (
        [string]$ResourceGroupName,
        [string]$VNetName,
        [string]$SubnetName,
        [string]$AddressPrefix
    )
    Write-Log "Criando Subnet '$SubnetName' na VNet '$VNetName'..." "INFO"
    $subnet = Add-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName) -AddressPrefix $AddressPrefix | Set-AzVirtualNetwork
    Write-Log "Subnet '$SubnetName' criada com sucesso." "SUCCESS"
}

# Criar VNET e Subnets
Create-VNet -ResourceGroupName "RG-$ClientNameUpper-Networks" -VNetName "VNET-$ClientNameUpper-Hub-001" -AddressPrefix "10.1.0.0/16" -Location $LocationBrazil
Add-Subnet -ResourceGroupName "RG-$ClientNameUpper-Networks" -VNetName "VNET-$ClientNameUpper-Hub-001" -SubnetName "SNET-$ClientNameUpper-Internal-001" -AddressPrefix "10.1.1.0/24"
Add-Subnet -ResourceGroupName "RG-$ClientNameUpper-Networks" -VNetName "VNET-$ClientNameUpper-Hub-001" -SubnetName "GatewaySubnet" -AddressPrefix "10.1.253.0/27"

# Função para criar NSG com regra para porta 3389 (RDP)
function Create-NSG {
    param (
        [string]$ResourceGroupName,
        [string]$NSGName,
        [string]$Location
    )

    Write-Log "Criando NSG '$NSGName' no grupo de recursos '$ResourceGroupName'..." "INFO"
    # Criar o NSG
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $NSGName -Location $Location -Tag @{"client"=$ClientNameLower; "environment"=$Environment; "technology"="firewall"}

    if ($null -ne $nsg) {
        # Adicionar regra para abrir a porta 3389 (RDP)
        Write-Log "Adicionando regra para abrir a porta 3389 (RDP)..." "INFO"
        $rule = New-AzNetworkSecurityRuleConfig -Name "Allow-RDP" `
                                                -Description "Allow RDP" `
                                                -Access Allow `
                                                -Protocol Tcp `
                                                -Direction Inbound `
                                                -Priority 1000 `
                                                -SourceAddressPrefix * `
                                                -SourcePortRange * `
                                                -DestinationAddressPrefix * `
                                                -DestinationPortRange 3389

        $nsg.SecurityRules += $rule
        Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null

        Write-Log "NSG '$NSGName' criado com sucesso." "SUCCESS"
        Write-Host ""
        $nsg | Format-Table -Property ResourceGroupName, Name, Location, ProvisioningState
    } else {
        Write-Log "Falha ao criar o NSG '$NSGName'." "ERROR"
    }
}

# Criar NSG
Create-NSG -ResourceGroupName "RG-$ClientNameUpper-Networks" -NSGName "NSG-$ClientNameUpper-Internal-001" -Location $LocationBrazil

# Função para criar endereço IP público
function Create-PublicIP {
    param (
        [string]$ResourceGroupName,
        [string]$IPName,
        [string]$Location,
        [string]$ClientNameLower,
        [string]$Environment
    )

    Write-Log "Criando endereço IP público '$IPName' no grupo de recursos '$ResourceGroupName' na região '$Location'..." "INFO"
    
    $publicIP = New-AzPublicIpAddress `
        -Name $IPName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -AllocationMethod Static `
        -Sku Standard `
        -Tag @{"client"=$ClientNameLower; "environment"=$Environment; "technology"="networking"}

    Write-Log "Endereço IP público '$IPName' criado com sucesso." "SUCCESS"
    $publicIP | Format-Table -Property Name, IpAddress, Location, ProvisioningState -AutoSize
    
    return $publicIP
}

# Criar IPs Públicos
Create-PublicIP -ResourceGroupName "RG-$ClientNameUpper-Networks" -IPName "PIP-VM-$VMName" -Location $LocationBrazil -ClientNameLower $ClientNameLower -Environment $Environment

# Função para criar VM
function Create-VM {
    param (
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$Location,
        [string]$AvailabilitySetId,
        [string]$SubnetId,
        [string]$NSGId,
        [string]$PublicIPResourceGroupName
    )
    
    # Credenciais da VM
    $adminUsername = $VMUsername
    $adminPassword = ConvertTo-SecureString $VMPassword -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($adminUsername, $adminPassword)
    
    Write-Log "Configurando a VM '$VMName' no grupo de recursos '$ResourceGroup' na região '$Location'..." "INFO"
    
    # Definir configuração da VM
    $vmConfig = New-AzVMConfig -VMName $VMName `
                               -VMSize "Standard_B2ms" `
                               -AvailabilitySetId $AvailabilitySetId
    
    # Desabilitar Boot Diagnostics
    Set-AzVMBootDiagnostic -VM $vmConfig -Enable $false | Out-Null
    
    # Definir perfil de sistema operacional
    Set-AzVMOperatingSystem -VM $vmConfig `
                            -Windows `
                            -ComputerName $VMName `
                            -Credential $cred `
                            -ProvisionVMAgent `
                            -EnableAutoUpdate | Out-Null
    
    # Definir perfil de rede
    Write-Log "Criando interface de rede para a VM '$VMName'..." "INFO"
    $nic = New-AzNetworkInterface -ResourceGroupName $ResourceGroup `
                                  -Name "$VMName-NIC" `
                                  -Location $Location `
                                  -SubnetId $SubnetId `
                                  -NetworkSecurityGroupId $NSGId `
                                  -PublicIpAddressId (Get-AzPublicIpAddress -ResourceGroupName $PublicIPResourceGroupName -Name "PIP-VM-$VMName").Id | Out-Null
    
    Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id | Out-Null
    
    # Definir perfil de armazenamento
    Set-AzVMOSDisk -VM $vmConfig `
                   -Name "$VMName-OSDisk" `
                   -CreateOption FromImage `
                   -Caching ReadWrite `
                   -StorageAccountType "StandardSSD_LRS" `
                   -DiskSizeInGB 127 | Out-Null
    
    # Definir imagem da VM
    Set-AzVMSourceImage -VM $vmConfig `
                        -PublisherName "MicrosoftWindowsServer" `
                        -Offer "WindowsServer" `
                        -Skus "2022-datacenter-azure-edition" `
                        -Version "latest" | Out-Null
    
    Write-Log "AVISO: Deploy da VM '$VMName' em andamento. Este processo pode levar alguns minutos. Por favor, aguarde..." "BOLD-YELLOW"
    
    # Criar a VM com Boot Diagnostics desabilitado
    $vm = New-AzVM -ResourceGroupName $ResourceGroup `
                   -Location $Location `
                   -VM $vmConfig | Out-Null
    
    Write-Log "VM '$VMName' criada com sucesso." "SUCCESS"
    
    # Obter informações adicionais da VM
    $vmDetails = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName
    $nicDetails = Get-AzNetworkInterface -ResourceGroupName $ResourceGroup -Name "$VMName-NIC"
    $publicIPDetails = Get-AzPublicIpAddress -ResourceGroupName $PublicIPResourceGroupName -Name "PIP-VM-$VMName"
    
    # Exibir informações formatadas sobre a VM criada
    $output = @{
        Name             = $vmDetails.Name
        Location         = $vmDetails.Location
        ProvisioningState= $vmDetails.ProvisioningState
        AvailabilitySet  = if ($vmDetails.AvailabilitySetReference) { ($vmDetails.AvailabilitySetReference.Id.Split('/')[-1]) } else { "N/A" }
        'IP Address'     = $nicDetails.IpConfigurations[0].PrivateIpAddress
        'Public IP'      = if ($publicIPDetails) { $publicIPDetails.IpAddress } else { "N/A" }
    }
    
    $output | Format-Table -AutoSize
}

# Criar Availability Set para primeira VM
Create-AvailabilitySet `
    -ResourceGroup "RG-$ClientNameUpper-VM" `
    -AvailabilitySetName "AS-$VMName" `
    -Location $LocationBrazil

# Criar primeira VM
Create-VM `
    -ResourceGroup "RG-$ClientNameUpper-VM" `
    -VMName $VMName `
    -Location $LocationBrazil `
    -AvailabilitySetId (Get-AzAvailabilitySet -ResourceGroupName "RG-$ClientNameUpper-VM" -Name "AS-$VMName").Id `
    -SubnetId (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName "RG-$ClientNameUpper-Networks" -Name "VNET-$ClientNameUpper-Hub-001") -Name "SNET-$ClientNameUpper-Internal-001").Id `
    -NSGId (Get-AzNetworkSecurityGroup -ResourceGroupName "RG-$ClientNameUpper-Networks" -Name "NSG-$ClientNameUpper-Internal-001").Id `
    -PublicIPResourceGroupName "RG-$ClientNameUpper-Networks"

# Criar segunda VM se solicitado
if ($CriarSegundaVM -and $SecondVMName) {
    # Criar Availability Set para segunda VM
    $ASName2 = "AS-$SecondVMName"
    Write-Log "Criando Availability Set '$ASName2'..." "INFO"
    $availabilitySet2 = New-AzAvailabilitySet `
        -ResourceGroupName "RG-$ClientNameUpper-VM" `
        -Name $ASName2 `
        -Location $LocationBrazil `
        -Sku Aligned `
        -PlatformFaultDomainCount 2 `
        -PlatformUpdateDomainCount 5

    Write-Log "Availability Set '$ASName2' criado com sucesso." "SUCCESS"

    # Criar IP Público para segunda VM
    $publicIP_VM2 = Create-PublicIP `
        -ResourceGroupName "RG-$ClientNameUpper-Networks" `
        -IPName "PIP-VM-$SecondVMName" `
        -Location $LocationBrazil `
        -ClientNameLower $ClientNameLower `
        -Environment $Environment

    # Criar segunda VM
    Write-Log "Iniciando a criação da VM '$SecondVMName'..." "INFO"
    Create-VM `
        -ResourceGroup "RG-$ClientNameUpper-VM" `
        -VMName $SecondVMName `
        -Location $LocationBrazil `
        -AvailabilitySetId $availabilitySet2.Id `
        -SubnetId (Get-AzVirtualNetworkSubnetConfig -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName "RG-$ClientNameUpper-Networks" -Name "VNET-$ClientNameUpper-Hub-001") -Name "SNET-$ClientNameUpper-Internal-001").Id `
        -NSGId (Get-AzNetworkSecurityGroup -ResourceGroupName "RG-$ClientNameUpper-Networks" -Name "NSG-$ClientNameUpper-Internal-001").Id `
        -PublicIPResourceGroupName "RG-$ClientNameUpper-Networks"
}

# Criar VPN se solicitado
if ($InstalarVPN) {
    # Função para criar VPN Gateway
    function Create-VPNGateway {
        param (
            [string]$ResourceGroup,
            [string]$Location,
            [string]$VNetName,
            [string]$GatewayName,
            [string]$ClientNameLower,
            [string]$Environment
        )

        Write-Log "Obtendo informações do VNet '$VNetName'..." "INFO"
        # Criar PIPs necessários para VPN
        Write-Log "Criando endereços IP públicos para VPN..." "INFO"
        Create-PublicIP -ResourceGroupName $ResourceGroup -IPName "PIP-S2S-PRIMARY" -Location $Location -ClientNameLower $ClientNameLower -Environment $Environment
        Create-PublicIP -ResourceGroupName $ResourceGroup -IPName "PIP-S2S-SECONDARY" -Location $Location -ClientNameLower $ClientNameLower -Environment $Environment
        Create-PublicIP -ResourceGroupName $ResourceGroup -IPName "PIP-P2S-PRIMARY" -Location $Location -ClientNameLower $ClientNameLower -Environment $Environment

        # Obter IP Público Primário e Secundário
        $publicIPPrimary = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name "PIP-S2S-PRIMARY"
        $publicIPSecondary = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name "PIP-S2S-SECONDARY"

        # Obter VNet e verificar GatewaySubnet
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $VNetName
        $gatewaySubnet = $vnet.Subnets | Where-Object { $_.Name -eq "GatewaySubnet" }

        if (-not $gatewaySubnet) {
            Write-Log "Sub-rede de Gateway não encontrada. Criando sub-rede de Gateway..." "WARNING"
            Add-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name "GatewaySubnet" -AddressPrefix "10.1.253.0/27"
            Set-AzVirtualNetwork -VirtualNetwork $vnet
            $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $VNetName
            $gatewaySubnet = $vnet.Subnets | Where-Object { $_.Name -eq "GatewaySubnet" }
        }

        Write-Log "Configurando IPs do Gateway..." "INFO"
        $gatewayIPConfigPrimary = New-AzVirtualNetworkGatewayIpConfig -Name "gwipconfig1" -SubnetId $gatewaySubnet.Id -PublicIpAddressId $publicIPPrimary.Id
        $gatewayIPConfigSecondary = New-AzVirtualNetworkGatewayIpConfig -Name "gwipconfig2" -SubnetId $gatewaySubnet.Id -PublicIpAddressId $publicIPSecondary.Id

        Write-Log "Deploy da VPN em andamento, favor aguardar..." "INFO"
        $vpnGateway = New-AzVirtualNetworkGateway `
            -ResourceGroupName $ResourceGroup `
            -Location $Location `
            -Name $GatewayName `
            -IpConfigurations @($gatewayIPConfigPrimary, $gatewayIPConfigSecondary) `
            -GatewayType "Vpn" `
            -VpnType "RouteBased" `
            -GatewaySku "VpnGw1" `
            -EnableActiveActiveFeature `
            -EnableBgp $false `
            -Tag @{"client"=$ClientNameLower; "environment"=$Environment; "technology"="vpn"}

        if ($vpnGateway.ProvisioningState -eq "Succeeded") {
            Write-Log "VPN Gateway '$GatewayName' criado com sucesso no grupo de recursos '$ResourceGroup'." "SUCCESS"
        } else {
            Write-Log "A criação do VPN Gateway '$GatewayName' falhou." "ERROR"
        }

        return $vpnGateway
    }

    # Criar VPN Gateway
    Write-Log "AVISO: Iniciando a criação do VPN Gateway. Este processo pode levar entre 30 minutos a uma hora. Por favor, aguarde..." "BOLD-YELLOW"
    $vpnGateway = Create-VPNGateway `
        -ResourceGroup "RG-$ClientNameUpper-Networks" `
        -Location $LocationBrazil `
        -VNetName "VNET-$ClientNameUpper-Hub-001" `
        -GatewayName "VNG-$ClientNameUpper" `
        -ClientNameLower $ClientNameLower `
        -Environment $Environment
}

Write-Log "Deploy dos recursos executado com sucesso. Script desenvolvido por Mathews Buzetti." "SUCCESS"
