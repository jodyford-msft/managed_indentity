@minLength(1)
param resourceGroupName string {
  metadata: {
    description: 'Name of the resource group'
  }
}

@minLength(1)
@allowedValues(validRegions)
param location string {
  metadata: {
    description: 'Location for resources'
  }
}

@minLength(1)
param sqlServerName string {
  metadata: {
    description: 'Name of the SQL server'
  }
}

@minLength(1)
param managedIdentityName string {
  metadata: {
    description: 'Name of the managed identity'
  }
}

@minLength(1)
param appServicePlanName string {
  metadata: {
    description: 'Name of the App Service plan'
  }
}

@minLength(1)
param webAppName string {
  metadata: {
    description: 'Name of the web app'
  }
}

@minLength(1)
param gitHubRepoUrl string {
  metadata: {
    description: 'URL of the GitHub repository'
  }
}

@minLength(1)
param gitHubBranch string {
  metadata: {
    description: 'Branch of the GitHub repository'
  }
}

@secure()
@minLength(1)
param gitHubToken string {
  metadata: {
    description: 'Personal access token for GitHub'
  }
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

resource sqlServer 'Microsoft.Sql/servers@2022-02-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-02-01-preview' = {
  name: 'adventureworks'
  parent: sqlServer
  properties: {
    sampleName: 'AdventureWorksLT'
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: managedIdentityName
  location: location
}

resource sqlServerIdentity 'Microsoft.Sql/servers/providers/roleAssignments@2021-04-01-preview' = {
  name: '${sqlServer.id}/Microsoft.Authorization/${guid(sqlServer.id, managedIdentity.id, 'db-reader')}'
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'db-reader-role-id') // Replace with the actual role ID
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
  scope: sqlServer
}

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'F1'
    tier: 'Free'
  }
}

resource webApp 'Microsoft.Web/sites@2021-02-01' = {
  name: webAppName
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
}

resource webAppDeployment 'Microsoft.Web/sites/sourcecontrols@2021-02-01' = {
  name: 'web'
  parent: webApp
  properties: {
    repoUrl: gitHubRepoUrl
    branch: gitHubBranch
    isManualIntegration: true
    isGitHubAction: true
    deploymentRollbackEnabled: true
    gitHubActionConfiguration: {
      token: gitHubToken
    }
  }
}

resource sqlPermissionScript 'Microsoft.Resources/deploymentScripts@2019-10-01-preview' = {
  name: 'grantSqlPermissions'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    azPowerShellVersion: '2.7'
    scriptContent: '''
      $managedIdentityPrincipalId = '${managedIdentity.properties.principalId}'
      $sqlServerName = '${sqlServerName}'
      $sqlDatabaseName = 'adventureworks'

      $connectionString = "Server=tcp:$sqlServerName.database.windows.net,1433;Initial Catalog=$sqlDatabaseName;Persist Security Info=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
      $query = "CREATE USER [$managedIdentityPrincipalId] FROM EXTERNAL PROVIDER; ALTER ROLE db_datareader ADD MEMBER [$managedIdentityPrincipalId]; ALTER ROLE db_datawriter ADD MEMBER [$managedIdentityPrincipalId];"

      $accessToken = (Get-AzAccessToken -ResourceUrl https://database.windows.net/).Token
      $connection = New-Object System.Data.SqlClient.SqlConnection
      $connection.ConnectionString = $connectionString
      $connection.AccessToken = $accessToken
      $connection.Open()

      $command = $connection.CreateCommand()
      $command.CommandText = $query
      $command.ExecuteNonQuery()

      $connection.Close()
    '''
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
  }
}

