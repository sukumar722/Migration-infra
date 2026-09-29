terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.region }

data "aws_caller_identity" "me" {}
data "aws_availability_zones" "az" { state = "available" }

locals {
  ecr_uri = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${var.region}.amazonaws.com/demo-app"
}

# ---------- Network ----------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name               = "demo-vpc"
  cidr               = "10.0.0.0/16"
  azs                = slice(data.aws_availability_zones.az.names, 0, 2)
  private_subnets    = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets     = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ---------- EKS ----------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                             = "demo-eks"
  cluster_version                          = var.eks_version
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.micro"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }
}

# ---------- ECR ----------
resource "aws_ecr_repository" "app" {
  name                 = "demo-app"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

# ---------- Artifact bucket ----------
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "demo-pipeline-artifacts-"
  force_destroy = true
}

# ---------- CodeBuild ----------
data "aws_iam_policy_document" "assume_codebuild" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
    ]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.me.account_id}:secret:demo/github-pat-*"]
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "demo-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.assume_codebuild.json
}

resource "aws_iam_role_policy" "codebuild" {
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

resource "aws_codebuild_project" "build" {
  name         = "demo-app-build"
  service_role = aws_iam_role.codebuild.arn

  artifacts { type = "CODEPIPELINE" }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # needed for docker build

    environment_variable {
      name  = "ECR_URI"
      value = local.ecr_uri
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.me.account_id
    }
    environment_variable {
      name  = "GITHUB_USER"
      value = var.github_user
    }
  }
}

# ---------- CodePipeline ----------
resource "aws_codestarconnections_connection" "github" {
  name          = "github-conn"
  provider_type = "GitHub"
}

data "aws_iam_policy_document" "assume_pipeline" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = [aws_codebuild_project.build.arn]
  }
  statement {
    actions   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "demo-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.assume_pipeline.json
}

resource "aws_iam_role_policy" "pipeline" {
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

resource "aws_codepipeline" "app" {
  name     = "demo-app-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["src"]
      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = "${var.github_user}/demo-app"
        BranchName       = "main"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name            = "BuildScanPushUpdate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["src"]
      configuration   = { ProjectName = aws_codebuild_project.build.name }
    }
  }
}
