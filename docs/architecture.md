# Workflow

1. Create an AMI from a dedicated image-builder instance.
2. Wait until the AMI is available.
3. Read the current Launch Template data.
4. Create a new LT version, changing only the AMI ID.
5. Update the ASG to use the new LT version.
6. Start Instance Refresh after approval.
7. Monitor refresh and verify ALB target health.

Production adaptation requires production-specific account IDs, resource IDs, IAM permissions, capacity settings, health checks, and approvals. Never copy POC identifiers into production.
