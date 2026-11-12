# rr-demo-infra

AWS CLI + Bash + Jenkins POC automation. No Terraform or CloudFormation.

## Safety
- Copy `config/poc.env.example` to `config/poc.env`; the latter is git-ignored.
- All mutating scripts are dry-run unless `APPLY=true`.
- Scripts verify the expected AWS account ID.
- Use a dedicated image-builder instance, not an ASG member or serving application instance.
- Never commit credentials, private keys, Rails secrets, or database passwords.
- Updating an ASG's LT changes future launches; Instance Refresh is what replaces existing instances.
- Instance Refresh is disruptive. Run only after review and approval.

## Setup
```bash
cp config/poc.env.example config/poc.env
vi config/poc.env
chmod +x scripts/*.sh
```
Fill in the dedicated source instance ID, actual ASG name, and target group ARN. Confirm the expected account ID.

## Run one step at a time
```bash
./scripts/01-preflight.sh
APPLY=true ./scripts/02-create-ami.sh
APPLY=true ./scripts/03-create-lt-version.sh
APPLY=true ./scripts/04-update-asg.sh
APPLY=true ./scripts/05-start-instance-refresh.sh
./scripts/06-verify-refresh.sh
```

`07-create-asg.sh` is only for a new separate ASG. It exits if the configured ASG already exists.

`NO_REBOOT=false` is safer for filesystem consistency but reboots the source. Use a dedicated image-builder. `NO_REBOOT=true` avoids rebooting but carries a consistency trade-off.

Rollback restores the ASG's previous LT version for future launches. It does not automatically start a recovery refresh.
