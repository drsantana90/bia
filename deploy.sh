#!/bin/bash

# Script de Deploy ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0.0

set -e

# Configurações padrão
DEFAULT_CLUSTER="cluster-bia"
DEFAULT_SERVICE="service-bia"
DEFAULT_TASK_DEFINITION="task-def-bia"
DEFAULT_ECR_REPO="bia"
DEFAULT_REGION="us-east-1"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir help
show_help() {
    cat << EOF
${BLUE}Script de Deploy ECS - Projeto BIA${NC}

${YELLOW}DESCRIÇÃO:${NC}
    Script para fazer build e deploy de aplicações no Amazon ECS com versionamento
    baseado em commit hash, permitindo rollbacks para versões anteriores.

${YELLOW}USO:${NC}
    $0 [COMANDO] [OPÇÕES]

${YELLOW}COMANDOS:${NC}
    deploy          Faz build da imagem e deploy no ECS
    rollback        Faz rollback para uma versão anterior
    list            Lista as últimas versões disponíveis
    help            Exibe esta ajuda

${YELLOW}OPÇÕES PARA DEPLOY:${NC}
    -c, --cluster       Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)
    -s, --service       Nome do serviço ECS (padrão: $DEFAULT_SERVICE)
    -t, --task-def      Nome da task definition (padrão: $DEFAULT_TASK_DEFINITION)
    -r, --repo          Nome do repositório ECR (padrão: $DEFAULT_ECR_REPO)
    -g, --region        Região AWS (padrão: $DEFAULT_REGION)
    --no-build          Pula a etapa de build (usa imagem existente)

${YELLOW}OPÇÕES PARA ROLLBACK:${NC}
    -v, --version       Hash do commit para rollback (obrigatório)
    -c, --cluster       Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)
    -s, --service       Nome do serviço ECS (padrão: $DEFAULT_SERVICE)
    -t, --task-def      Nome da task definition (padrão: $DEFAULT_TASK_DEFINITION)
    -r, --repo          Nome do repositório ECR (padrão: $DEFAULT_ECR_REPO)
    -g, --region        Região AWS (padrão: $DEFAULT_REGION)

${YELLOW}EXEMPLOS:${NC}
    # Deploy básico
    $0 deploy

    # Deploy com configurações customizadas
    $0 deploy -c meu-cluster -s meu-service -r meu-repo

    # Rollback para versão específica
    $0 rollback -v abc123f

    # Listar versões disponíveis
    $0 list

    # Pular build e usar imagem existente
    $0 deploy --no-build

${YELLOW}FLUXO DO DEPLOY:${NC}
    1. Obtém o hash do commit atual (últimos 7 caracteres)
    2. Faz build da imagem Docker com tag baseada no commit
    3. Faz push da imagem para o ECR
    4. Cria nova revisão da task definition
    5. Atualiza o serviço ECS
    6. Aguarda o deploy completar

${YELLOW}FLUXO DO ROLLBACK:${NC}
    1. Verifica se a imagem existe no ECR
    2. Cria nova revisão da task definition com a imagem anterior
    3. Atualiza o serviço ECS
    4. Aguarda o rollback completar

EOF
}

# Função para log colorido
log() {
    local level=$1
    shift
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $*" ;;
    esac
}

# Função para verificar dependências
check_dependencies() {
    local deps=("docker" "aws" "git" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log "ERROR" "Dependência não encontrada: $dep"
            exit 1
        fi
    done
}

# Função para obter commit hash
get_commit_hash() {
    git rev-parse --short=7 HEAD 2>/dev/null || {
        log "ERROR" "Não foi possível obter o hash do commit. Certifique-se de estar em um repositório git."
        exit 1
    }
}

# Função para obter account ID
get_account_id() {
    aws sts get-caller-identity --query Account --output text --region $REGION
}

# Função para fazer build da imagem
build_image() {
    local commit_hash=$1
    local ecr_repo=$2
    local region=$3
    
    log "INFO" "Iniciando build da imagem com tag: $commit_hash"
    
    # Build da imagem
    docker build -t $ecr_repo:$commit_hash . || {
        log "ERROR" "Falha no build da imagem"
        exit 1
    }
    
    log "INFO" "Build concluído com sucesso"
}

# Função para fazer push para ECR
push_to_ecr() {
    local commit_hash=$1
    local ecr_repo=$2
    local region=$3
    
    local account_id=$(get_account_id)
    local ecr_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo"
    
    log "INFO" "Fazendo login no ECR..."
    aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $ecr_uri || {
        log "ERROR" "Falha no login do ECR"
        exit 1
    }
    
    # Tag da imagem para ECR
    docker tag $ecr_repo:$commit_hash $ecr_uri:$commit_hash
    
    log "INFO" "Fazendo push da imagem para ECR..."
    docker push $ecr_uri:$commit_hash || {
        log "ERROR" "Falha no push para ECR"
        exit 1
    }
    
    log "INFO" "Push concluído com sucesso"
    # Retornar apenas a URI sem logs
    echo "$ecr_uri:$commit_hash"
}

# Função para criar task definition
create_task_definition() {
    local image_uri=$1
    local task_def_name=$2
    local region=$3
    
    log "INFO" "Criando nova revisão da task definition..."
    
    # Obter task definition atual
    local current_task_def=$(aws ecs describe-task-definition \
        --task-definition $task_def_name \
        --region $region \
        --query 'taskDefinition' 2>/dev/null || echo "null")
    
    if [ "$current_task_def" = "null" ]; then
        log "ERROR" "Task definition '$task_def_name' não encontrada"
        exit 1
    fi
    
    # Criar nova task definition com nova imagem
    local new_task_def=$(echo $current_task_def | jq --arg image "$image_uri" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    local new_revision=$(aws ecs register-task-definition \
        --region $region \
        --cli-input-json "$new_task_def" \
        --query 'taskDefinition.revision' \
        --output text) || {
        log "ERROR" "Falha ao registrar nova task definition"
        exit 1
    }
    
    log "INFO" "Nova task definition criada: $task_def_name:$new_revision"
    # Retornar apenas o ARN sem logs
    echo "$task_def_name:$new_revision"
}

# Função para atualizar serviço ECS
update_service() {
    local task_def_arn=$1
    local cluster=$2
    local service=$3
    local region=$4
    
    log "INFO" "Atualizando serviço ECS..."
    
    aws ecs update-service \
        --cluster $cluster \
        --service $service \
        --task-definition $task_def_arn \
        --region $region \
        --query 'service.serviceName' \
        --output text > /dev/null || {
        log "ERROR" "Falha ao atualizar serviço ECS"
        exit 1
    }
    
    log "INFO" "Serviço atualizado, aguardando deploy..."
    
    # Aguardar deploy completar
    aws ecs wait services-stable \
        --cluster $cluster \
        --services $service \
        --region $region || {
        log "ERROR" "Timeout aguardando deploy"
        exit 1
    }
    
    log "INFO" "Deploy concluído com sucesso!"
}

# Função para verificar se imagem existe no ECR
check_image_exists() {
    local commit_hash=$1
    local ecr_repo=$2
    local region=$3
    
    aws ecr describe-images \
        --repository-name $ecr_repo \
        --image-ids imageTag=$commit_hash \
        --region $region \
        --query 'imageDetails[0].imageTags[0]' \
        --output text 2>/dev/null || echo "None"
}

# Função para listar versões
list_versions() {
    local ecr_repo=$1
    local region=$2
    
    log "INFO" "Listando últimas 10 versões disponíveis:"
    
    aws ecr describe-images \
        --repository-name $ecr_repo \
        --region $region \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table || {
        log "ERROR" "Falha ao listar versões"
        exit 1
    }
}

# Função principal de deploy
deploy() {
    local cluster=$1
    local service=$2
    local task_def=$3
    local ecr_repo=$4
    local region=$5
    local no_build=$6
    
    check_dependencies
    
    local commit_hash=$(get_commit_hash)
    log "INFO" "Iniciando deploy para commit: $commit_hash"
    
    local image_uri
    if [ "$no_build" = "true" ]; then
        local account_id=$(get_account_id)
        image_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo:$commit_hash"
        
        # Verificar se imagem existe
        local exists=$(check_image_exists $commit_hash $ecr_repo $region)
        if [ "$exists" = "None" ]; then
            log "ERROR" "Imagem $commit_hash não encontrada no ECR"
            exit 1
        fi
        log "INFO" "Usando imagem existente: $image_uri"
    else
        build_image $commit_hash $ecr_repo $region
        
        # Push para ECR
        local account_id=$(get_account_id)
        local ecr_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo"
        
        log "INFO" "Fazendo login no ECR..."
        aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $ecr_uri || {
            log "ERROR" "Falha no login do ECR"
            exit 1
        }
        
        # Tag da imagem para ECR
        docker tag $ecr_repo:$commit_hash $ecr_uri:$commit_hash
        
        log "INFO" "Fazendo push da imagem para ECR..."
        docker push $ecr_uri:$commit_hash || {
            log "ERROR" "Falha no push para ECR"
            exit 1
        }
        
        log "INFO" "Push concluído com sucesso"
        image_uri="$ecr_uri:$commit_hash"
    fi
    
    # Criar nova task definition
    log "INFO" "Criando nova revisão da task definition..."
    
    # Obter task definition atual
    local current_task_def=$(aws ecs describe-task-definition \
        --task-definition $task_def \
        --region $region \
        --query 'taskDefinition' 2>/dev/null || echo "null")
    
    if [ "$current_task_def" = "null" ]; then
        log "ERROR" "Task definition '$task_def' não encontrada"
        exit 1
    fi
    
    # Criar nova task definition com nova imagem
    local new_task_def=$(echo $current_task_def | jq --arg image "$image_uri" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    local new_revision=$(aws ecs register-task-definition \
        --region $region \
        --cli-input-json "$new_task_def" \
        --query 'taskDefinition.revision' \
        --output text) || {
        log "ERROR" "Falha ao registrar nova task definition"
        exit 1
    }
    
    log "INFO" "Nova task definition criada: $task_def:$new_revision"
    local new_task_def_arn="$task_def:$new_revision"
    
    # Atualizar serviço ECS
    log "INFO" "Atualizando serviço ECS..."
    
    aws ecs update-service \
        --cluster $cluster \
        --service $service \
        --task-definition $new_task_def_arn \
        --region $region \
        --query 'service.serviceName' \
        --output text > /dev/null || {
        log "ERROR" "Falha ao atualizar serviço ECS"
        exit 1
    }
    
    log "INFO" "Serviço atualizado, aguardando deploy..."
    
    # Aguardar deploy completar
    aws ecs wait services-stable \
        --cluster $cluster \
        --services $service \
        --region $region || {
        log "ERROR" "Timeout aguardando deploy"
        exit 1
    }
    
    log "INFO" "Deploy finalizado!"
    log "INFO" "Versão atual: $commit_hash"
}

# Função de rollback
rollback() {
    local version=$1
    local cluster=$2
    local service=$3
    local task_def=$4
    local ecr_repo=$5
    local region=$6
    
    check_dependencies
    
    if [ -z "$version" ]; then
        log "ERROR" "Versão para rollback é obrigatória"
        exit 1
    fi
    
    log "INFO" "Iniciando rollback para versão: $version"
    
    # Verificar se imagem existe
    local exists=$(check_image_exists $version $ecr_repo $region)
    if [ "$exists" = "None" ]; then
        log "ERROR" "Versão $version não encontrada no ECR"
        exit 1
    fi
    
    local account_id=$(get_account_id)
    local image_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo:$version"
    
    local new_task_def
    new_task_def=$(create_task_definition $image_uri $task_def $region)
    update_service "$new_task_def" $cluster $service $region
    
    log "INFO" "Rollback finalizado!"
    log "INFO" "Versão atual: $version"
}

# Parse dos argumentos
COMMAND=""
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
TASK_DEF=$DEFAULT_TASK_DEFINITION
ECR_REPO=$DEFAULT_ECR_REPO
REGION=$DEFAULT_REGION
VERSION=""
NO_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|rollback|list|help)
            COMMAND=$1
            shift
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -t|--task-def)
            TASK_DEF="$2"
            shift 2
            ;;
        -r|--repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -g|--region)
            REGION="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        --no-build)
            NO_BUILD=true
            shift
            ;;
        *)
            log "ERROR" "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Executar comando
case $COMMAND in
    deploy)
        deploy $CLUSTER $SERVICE $TASK_DEF $ECR_REPO $REGION $NO_BUILD
        ;;
    rollback)
        rollback $VERSION $CLUSTER $SERVICE $TASK_DEF $ECR_REPO $REGION
        ;;
    list)
        list_versions $ECR_REPO $REGION
        ;;
    help|"")
        show_help
        ;;
    *)
        log "ERROR" "Comando inválido: $COMMAND"
        show_help
        exit 1
        ;;
esac
