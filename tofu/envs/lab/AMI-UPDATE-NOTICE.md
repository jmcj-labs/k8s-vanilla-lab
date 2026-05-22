# AMI Auto-Update Behavior

## Current Behavior
The `data.aws_ami.ubuntu` data source in `tofu/envs/lab/main.tf` uses `most_recent = true`, which means:

- Every `tofu plan` will check for the latest Ubuntu 24.04 LTS AMI from Canonical
- If a new AMI is published, Terraform will propose **replacing all instances**
- This is **destructive** — existing cluster state will be lost

## Impact
✅ **Acceptable for lab environments**: Always get latest security patches  
⚠️ **Risky for production**: Unexpected instance replacements during plan/apply

## Mitigation Options

### Option 1: Pin AMI ID (Recommended for Stability)
In `tofu/envs/lab/variables.tf`, add:
```hcl
variable "ami_id" {
  description = "Ubuntu 24.04 AMI ID (optional, auto-detected if not set)"
  type        = string
  default     = ""
}
```

In `main.tf`, change data source to:
```hcl
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  # ... existing filters
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
}
```

Then pass `ami_id = local.ami_id` to modules.

### Option 2: Ignore AMI Changes (Already Implemented)
The `lifecycle { ignore_changes = [ami] }` block in both modules prevents replacements:
- Control plane: `tofu/modules/control-plane/main.tf` line ~190
- Workers: `tofu/modules/worker/main.tf` line ~210

This means:
- First deployment uses latest AMI
- Subsequent plans ignore AMI updates
- Manual AMI updates require `terraform taint`

## Current Configuration
✅ **Lifecycle ignore_changes already applied** in both modules  
✅ No unexpected replacements will occur  
📝 To update AMI: `tofu taint module.control_plane.aws_instance.control_plane`

## Verification
```bash
cd tofu/envs/lab
tofu plan  # Should NOT show instance replacements due to AMI changes
```
