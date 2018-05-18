<#
.SYNOPSIS
    Reports on backup policies and status for existing App Services

.DESCRIPTION
    This Runbook will review deployed services in all subscriptions available to the PSCredential used to login
    unless otherwise restricted through filtering (see below).  It will review each App Service to determine the following:
 
    * If a backup is configured
    * If the backup is currently enabled
    * Retention policy of backup images
    * When the last backup was started
    * When the last backup was finished
    * Status of last backup attempt

    When the above information is collected, it will generate different output based on the backup policy and current status.

.PARAMETER mfdebug
    Constant ($true or $false) defining whether or not we want to execute this in debug mode

.PARAMETER subscriptionsToCheck
    Comma delimited list of subscriptions to check

.NOTES
	Author: Mike Fink
	Last Updated: 5/18/2018
    Version 1.0
#>
	
 ##############################################################################
 # This section contains the input variables that are needed for the runbook
 # to work as expected. Input paramters can be replaced with hardcoded variables
 # within the script if needed. See inspiration below. 
 ############################################################################## 
 Param
 (            
     [parameter(Mandatory=$false)]
     [bool]
     $mfdebug = $true, 
     
     [parameter(Mandatory=$false)]
     [array]
     $subscriptionsToCheck = @("Cloud Subscription 1", "Cloud Subscription 2")
)

$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

# Gather all of the subscriptions the account has access to (this is an alternative way to approach if you want to determine on-the-fly)
#$subscriptions = Get-AzureRmSubscription

# Keep track of the number of issues
# An issue could be no backups configured - or - backups are configured but the last one failed
$numNotConfigured = 0
$numFails = 0

# Iterate over the subscriptions and grab the webapps
foreach($subscription in $subscriptionsToCheck)
{
    Write-Output ("Checking subscription <" + $subscription + ">")

    # Switch to the first (or next) subscription
    Select-AzureRmSubscription -SubscriptionName $subscription

    $subscription = Get-AzureRmSubscription | Where-Object {$_.Name -eq $subscription}

    # Something went wrong and the subscription doesn't exist
    if(!$subscription.Name)
    {
        Write-Error("This subscription ^^^^ is not visible to the Service Principal account")
        break
    }

    # Gather all of the web apps within the subscription
    $webApps = Get-AzureRmWebApp

    # Iterate over the Web Apps and gather info
    foreach ($webApp in $webApps)
    {
        # Container array that will contain the info, need to start each app with an empty set
        $backupOneLiner = @()

        Write-Output ("--> Checking App Service <" + $webApp.Name + ">") 
        # Grab the relevant information from the backup list as well as the configuration
        $lastBackup = Get-AzureRmWebAppBackupList -ResourceGroupName $webApp.ResourceGroup -Name $webApp.Name -EA SilentlyContinue | Select-Object -Last 1
        $backupConfig = Get-AzureRmWebAppBackupConfiguration -ResourceGroupName $webApp.ResourceGroup -Name $webApp.Name 

        $lastSuccessful = Get-AzureRmWebAppBackupList -ResourceGroupName $webApp.ResourceGroup -Name $webApp.Name | Sort-Object -Property Finished | Where-Object {$_.BackupStatus -eq "Succeeded"} | Select-Object -Last 1

        # If there is no backup configured we need to report that in the 'IsEnabled' field
        # Assume it's NOT configured by default
        $isEnabled = $false

        # If anything is configured, then report the actual status
        if($backupConfig.Enabled -ne $null) 
        { 
            $isEnabled = $backupConfig.Enabled 
        }

        #If anything other than a good response, increase issue count
        if($isEnabled -ne $true)
        {
            $numNotConfigured++
            Write-Output("NO BACKUP CONFIGURED for AppService: <" + $webApp.Name + "> in subscription: <" + $subscription.Name + ">" )
        }

        if($lastBackup.BackupStatus -ieq "Failed")
        {
            $numFails++
            Write-Output("LAST BACKUP FAILED for AppService: <" + $webApp.Name + "> in subscription: <" + $subscription.Name + ">" )
        }
        
        if($lastSuccessful.Finished.ToLocalTime() -lt (Get-Date).AddDays(-5))
        {
            Write-Output("LAST BACKUP MORE THAN 5 DAYS OLD for AppService: <" + $webApp.Name + "> in subscription: <" + $subscription.Name + ">" )
        }

        Write-Output("STATUS -- SubscriptionName: <" + $subscription.Name +`
            "> SubscriptionID: <" + $subscription.Id +`
            "> AppServiceName: <" + $webApp.Name +`
            "> LastBackupStart: <" + $lastBackup.Created +`
            "> LastBackupFinished: <" + $lastBackup.Finished +`
            "> LastBackupStatus: <" + $lastBackup.BackupStatus +`
            "> RetentionPeriod: <" + $backupConfig.RetentionPeriodInDays +`
            "> IsEnabled: <" + $isEnabled + ">")

        #>
        #if($debug) { break }
    }   
    #if($debug) { break }
}

# Prepare the summary
$totalIssues = $numNotConfigured + $numFails
$subject = "Cloud Report - App Service Backup configuration status <"+$totalIssues+"> issues to review"
if($totalIssues -eq 0)
{
    $body = "There are NO issues to report"
    Write-Output $body
}
else
{
    $body = "App Services NOT configured for automated backups: <"+$numNotConfigured+">`n `
App Services that failed the last backup attempt: <"+$numFails+">`n `
Total issues to report: <"+$totalIssues+">`n"
    Write-Output $body
}


