# SFDCTools
Tools for SFDC

## sfdx_helpers.sh examples
```bash
export sfdc_url="example.my"
export sfdc_username="user@contoso.com"
export sfdc_password="mypassword"
export sfdc_security_token="mysecuritytoken"

./sfdx_helpers.sh

install_salesforce_cli

install_jq

authenticate SFDC $sfdc_username $sfdc_password $sfdc_security_token $sfdc_url

deploy_metadata SFDC

```
