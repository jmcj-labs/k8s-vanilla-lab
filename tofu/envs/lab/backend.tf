terraform {
  backend "s3" {
    bucket         = "k8s-vanilla-lab-tfstate-487985088962"
    key            = "k8s-vanilla-lab/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "k8s-vanilla-lab-tflock"

    # Required for state locking
    # DynamoDB table must have LockID as partition key (String)
  }
}
