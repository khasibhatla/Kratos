param ( 
    [Parameter(Mandatory=$true)]
    [string]$accessKey ="ACCESS_KEY",
    [Parameter(Mandatory=$true)]
    [ValidateSet("Stop","Start")]
    [string]$command ="Stop",       
    [Parameter(Mandatory=$true)]
    [string]$environment ="Internal",        
    [Parameter(Mandatory=$true)]
    [string]$secretKey ="SECRET_KEY",
    # Defaulting this to US-Virginia and this can be configured as needed
    [string]$region = "us-east-1",
    # Web and Workers are roles where ASGs are enforced, where as other roles are truly managed services with in AWS 
    [string]$roles = '[{"role":"web","min":0,"max":6}, {"role":"worker","min":0,"max":4}, {"role":"redis"}, {"role":"elasticsearch"}, {"role":"redshift"}]' 
)
Import-Module AWSPowerShell
$ErrorActionPreference = "Stop"
$asgs = New-Object System.Collections.ArrayList
$Tags = New-Object System.Collections.Hashtable
function FilterByRole($role)
{                
    $filter = New-Object Amazon.EC2.Model.Filter -Property @{Name='tag:Role'; Values= $role}
    return $filter    
}
function FilterByStatus($status)
{                
    $filter = New-Object Amazon.EC2.Model.Filter -Property @{Name='instance-state-code'; Values= $status}
    return $filter    
}
$filterByEnv = New-Object Amazon.EC2.Model.Filter -Property @{Name='tag:Env'; Values=$environment}

function HandleException($function,$exceptionMessage)
{                
    Write-Output = "Exception in $function => $exceptionMessage, hence exiting."
    throw $exceptionMessage
    exit 1
}
function ListAllAvailableASGs
{   
    $asgs = New-Object System.Collections.ArrayList
    $nextToken = $null
    do {
      $asg = Get-ASAutoScalingGroup -NextToken $nextToken -MaxRecord 1
      if($asg.AutoScalingGroupName.StartsWith($environment)){
        $asgs.Add($asg) > $null
      }
      $nextToken = $AWSHistory.LastServiceResponse.NextToken
    } while ($nextToken -ne $null)
    return $asgs
}
function StopInstances($rolename)
{        
    $filterByRole = FilterByRole($rolename)
    $instances = Get-EC2Instance -Filter $filterByRole -Region $region
    $output = "Found " + $instances.Count + " instances to stop at this time"
    Write-Output $output    
    if($instances.Count -gt 0){
        foreach($instance in $instances) {    
            Stop-EC2Instance -Instance $instance.Instances[0].InstanceId
        }
        Write-Output "Stopping instances with role $rolename on environment $environment"
    }
}
function StartInstances($rolename)
{    
    $filterByRole = FilterByRole($rolename)
    $instances = Get-EC2Instance -Filter $filterByRole -Region $region
    $output = "Found " + $instances.Count + " instances to start at this time"
    Write-Output $output    
    if($instances.Count -gt 0){
        foreach($instance in $instances) { 
            Start-EC2Instance -Instance $instance.Instances[0].InstanceId
        } 
        Write-Output "Starting instances with role $rolename on environment $environment"
    }
}
function GetTags($asg){    
    $tags = New-Object System.Collections.Hashtable
    foreach($localTag in $asg.Tags){
        $tags.Add($localTag.Key,$localTag)
    }
    return $tags
}
function EnforceRampUpPolicy($currentRole) {
    try{
        foreach($asg in $asgs){                      
            $localTags = GetTags($asg)                    
            if($localTags["Env"].Value -eq $environment -and $localTags["Role"].Value -eq $currentRole.role){
                Update-ASAutoScalingGroup -AutoScalingGroupName $asg.AutoScalingGroupName -MaxSize $currentRole.max -MinSize $currentRole.min -DesiredCapacity $currentRole.min
                $output = $currentRole.role.ToUpper() + " ASG with desired capacity in environment: $environment has been ramped up"
                Write-Output $output
            }            
        }        
    }
    Catch [Exception]
    {        
        HandleException "EnforceRampUpPolicy" $_.Exception.Message         
    }
}
function EnforceTearDownPolicy($currentRole) {
    try{               
        foreach($asg in $asgs){                      
            $localTags = GetTags($asg)                    
            if($localTags["Env"].Value -eq $environment -and $localTags["Role"].Value -eq $currentRole.role){
                Update-ASAutoScalingGroup -AutoScalingGroupName $asg.AutoScalingGroupName -MaxSize $currentRole.max -MinSize 0 -DesiredCapacity 0  
                $output = $currentRole.role.ToUpper() + " ASG scaled down with desired capacity in environment: $environment"
                Write-Output $output       
            }            
        }
    }    
    Catch [Exception]{        
        HandleException "EnforceTearDownPolicy" $_.Exception.Message         
    }
}
function UnleashKratos($command){
    $asgs = ListAllAvailableASGs
    try{
        switch($command.ToLower())
        {
            "stop" {
                    foreach($role in $toDeploy) {                        
                        if($role.role -eq "web" -or $role.role -eq "worker"){
                            EnforceTearDownPolicy($role)
                        }
                        else{
                            StopInstances($role.role)
                        }
                    }
            }                                    
            "start" {                    
                    foreach($role in $toDeploy) {                                                
                        if($role.role -eq "web" -or $role.role -eq "worker"){
                            EnforceRampUpPolicy($role)                        
                        }
                        else {
                            StartInstances($role.role)
                        }
                    }
            }                            
            default {
                    "Unknown command issued on environment: $environment"        
            }
        }
    }
    Catch [Exception]{
        HandleException "UnleashKratos" $_.Exception.Message 
        exit 1
    }
}
try
{   $toDeploy = ConvertFrom-Json $roles 
    $output = "Found " + $toDeploy.Count + " roles to process"
    Write-Output $output    
}
Catch [Exception]{  
    HandleException "ConvertFrom-Json" $_.Exception.Message 
    $command = "Stop"
}
try
{       
    Set-AWSCredentials -AccessKey $accesskey -SecretKey $secretkey
    Set-DefaultAWSRegion -Region $region    
    UnleashKratos($command)    
}
Catch [Exception]
{       
    HandleException "Setting-AWS-Profile" $_.Exception.Message 
    $command = "Stop"
}