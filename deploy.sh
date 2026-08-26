#!/bin/bash

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | xargs)
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default values
ENVIRONMENT="dev"
ACTION="plan"

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -e, --environment ENV    Environment (dev, staging, prod) [default: dev]"
    echo "  -a, --action ACTION      Terraform action (plan, apply, destroy) [default: plan]"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --action plan"
    echo "  $0 --environment dev --action apply"
    echo "  $0 --action destroy"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -a|--action)
            ACTION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option $1"
            show_help
            exit 1
            ;;
    esac
done


if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    print_error "Invalid environment: $ENVIRONMENT. Must be dev, staging, or prod."
    exit 1
fi

if [[ ! "$ACTION" =~ ^(plan|apply|destroy)$ ]]; then
    print_error "Invalid action: $ACTION. Must be plan, apply, or destroy."
    exit 1
fi

print_status "Starting deployment for environment: $ENVIRONMENT"
print_status "Action: $ACTION"

cd infrastructure



print_status "AWS credentials validated"

print_status "Initializing Terraform..."
terraform init -reconfigure \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -backend-config="region=${AWS_DEFAULT_REGION}"

print_status "Validating Terraform configuration..."
terraform validate

print_status "Checking Terraform formatting..."
terraform fmt -check

case $ACTION in
    plan)
        print_status "Running Terraform plan..."
        terraform plan -var-file="terraform.tfvars"
        ;;
    apply)
        print_warning "This will apply changes to AWS resources!"
        read -p "Are you sure you want to continue? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Applying Terraform changes..."
            terraform apply -var-file="terraform.tfvars" -auto-approve
            print_status "Deployment completed successfully!"
        else
            print_status "Deployment cancelled"
            exit 0
        fi
        ;;
    destroy)
        print_warning "This will DESTROY AWS resources!"
        read -p "Are you sure you want to destroy resources? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "Destroying Terraform resources..."
            terraform destroy -var-file="terraform.tfvars" -auto-approve
            print_status "Resources destroyed successfully!"
        else
            print_status "Destroy cancelled"
            exit 0
        fi
        ;;
esac

print_status "Script completed successfully!"
