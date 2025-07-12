# SpiceDB Schema V2 Migration Guide

## Overview

Schema V2 introduces a hierarchical IAM model with the following new entities:
- **Organizational Units (OUs)**: Nested subdivisions within organizations
- **Projects**: Containers for resources (VMs, etc.)
- **Environments**: Deployment environments within projects (dev, staging, prod)
- **Resource Quotas**: Limits at organization, OU, or project level

## Key Changes

### 1. VM Ownership
- **Before**: VMs belong directly to organizations
- **After**: VMs belong to projects (which belong to organizations or OUs)

### 2. Permission Inheritance
- Permissions now cascade down the hierarchy
- Organization admin → OU admin → Project admin → Resource permissions

### 3. New Relationships
```
Organization
├── Organizational Unit
│   ├── Sub-OU
│   └── Project
│       ├── Environment
│       └── VM
└── Project (direct)
    ├── Environment
    └── VM
```

## Migration Steps

### 1. Database Migration
```bash
# Run in control-plane directory
cd control-plane
swift run App migrate
```

This will:
- Create new tables for OUs, Projects, Environments, and Resource Quotas
- Add project_id and environment fields to VMs
- Create default projects for existing organizations

### 2. SpiceDB Schema Update
```bash
cd spicedb
./migrate_to_v2.sh
```

### 3. Data Migration

Run the data migration script to:
- Create SpiceDB relationships for default projects
- Update VM relationships from organization to project
- Set default environment for all VMs

### 4. Application Code Updates

Update the following services:
- `SpiceDBService`: Use new entity types
- `VMController`: Include project context
- `OrganizationController`: Support hierarchy

## Backward Compatibility

During migration:
- Old organization-based permissions continue to work
- Default projects are created automatically
- VMs without projects are assigned to org's default project

## Rollback Plan

If issues occur:
1. Revert SpiceDB schema: `zed schema write schema.zed`
2. Run database rollback: `swift run App migrate --revert`
3. Restore from backup if needed

## Testing

After migration:
1. Verify existing users can still access their VMs
2. Test creating new VMs in projects
3. Verify permission inheritance works correctly
4. Test environment-specific permissions