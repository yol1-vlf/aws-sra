#!/bin/bash

# Script para desplegar AWS SRA GitHub OIDC Solution
# Uso: ./deploy-github-oidc-solution.sh [AWS_PROFILE] [PARAMETERS_FILE]

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para imprimir mensajes con colores
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# ========================================
# 1. OBTENCIÓN DE VARIABLES
# ========================================

print_section "1. OBTENCIÓN DE VARIABLES"

# Obtener el nombre de la rama de GitHub desde el repositorio actual
GITHUB_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
PARAMETERS_FILE="sra-parameters-${GITHUB_BRANCH}.json"

print_info "Rama de GitHub: $GITHUB_BRANCH"
print_info "Archivo de parámetros: $PARAMETERS_FILE"

# Verificar que el archivo de parámetros exista
if [ ! -f "$PARAMETERS_FILE" ]; then
    print_error "Archivo $PARAMETERS_FILE no encontrado"
    print_info "Archivos disponibles:"
    ls -la sra-parameters-*.json 2>/dev/null || print_warning "No se encontraron archivos de parámetros"
    exit 1
fi

# Verificar que el archivo de parámetros sea JSON válido
if ! jq empty "$PARAMETERS_FILE" 2>/dev/null; then
    print_error "El archivo $PARAMETERS_FILE no es un JSON válido"
    exit 1
fi

print_info "Archivo de parámetros validado: $PARAMETERS_FILE"

# Leer el valor de pAWSProfile desde la sección "common" del archivo de parámetros
AWS_PROFILE=$(jq -r '.common.parameters[] | select(.ParameterKey=="pAWSProfile") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")

# Verificar que AWS CLI esté configurado
if [[ -n "$AWS_PROFILE" ]]; then
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "AWS CLI no está configurado con el perfil $AWS_PROFILE. Por favor, ejecuta 'aws sso login --profile $AWS_PROFILE' primero."
        exit 1
    fi
else
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI no está configurado. Por favor, configura tus credenciales de AWS."
        exit 1
    fi
fi

# Obtener información de la cuenta y región
if [[ -n "$AWS_PROFILE" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
else
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi

AWS_REGION=$(jq -r '.common.parameters[] | select(.ParameterKey=="pAWSRegion") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")

# Validar que la región esté definida
if [[ -z "$AWS_REGION" ]]; then
    print_error "No se pudo obtener la región AWS desde el archivo de parámetros"
    exit 1
fi

print_info "Cuenta AWS: $ACCOUNT_ID"
print_info "Perfil AWS: $AWS_PROFILE"
print_info "Región: $AWS_REGION"

# Definir variables del stack
STACK_NAME=$(jq -r '.rGitHubOIDCSolutionStack.parameters[] | select(.ParameterKey=="pSRASolutionName") | .ParameterValue' "$PARAMETERS_FILE")
TEMPLATE_FILE="aws_sra/solutions/github-oidc/deploy.yaml"
OIDC_FILE="aws_sra/solutions/github-oidc/oidc.yaml"

print_info "Stack: $STACK_NAME"
print_info "Template: $TEMPLATE_FILE"
print_info "OIDC File: $OIDC_FILE"

# Extraer parámetros específicos de GitHub OIDC
print_info "Extrayendo parámetros de GitHub OIDC..."

# Función para extraer parámetros de una sección específica
extract_section_params() {
    local section="$1"
    jq -r --arg section "$section" '.[$section].parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMETERS_FILE" 2>/dev/null || echo ""
}

# Extraer parámetros de GitHub OIDC
GITHUB_OIDC_PARAMS=$(extract_section_params "rGitHubOIDCSolutionStack")

if [ -z "$GITHUB_OIDC_PARAMS" ]; then
    print_error "No se pudieron extraer parámetros de GitHub OIDC del archivo $PARAMETERS_FILE"
    exit 1
fi

print_info "Parámetros extraídos para el despliegue:"
echo "$GITHUB_OIDC_PARAMS"

# Convertir los parámetros a formato para CloudFormation deploy
GITHUB_OIDC_PARAMS=$(echo "$GITHUB_OIDC_PARAMS" | tr '\n' ' ')

if [ -z "$GITHUB_OIDC_PARAMS" ]; then
    print_error "No se pudieron extraer parámetros de GitHub OIDC del archivo $PARAMETERS_FILE"
    exit 1
fi

print_info "Parámetros de GitHub OIDC extraídos exitosamente"

# ========================================
# 2. OBTENER NOMBRE DEL BUCKET S3
# ========================================

print_section "2. OBTENER NOMBRE DEL BUCKET S3"

SSM_BUCKET_PARAM="/sra/staging-s3-bucket-name"

print_info "Obteniendo nombre del bucket S3 desde SSM..."

aws_cmd="aws ssm get-parameter --name $SSM_BUCKET_PARAM --query 'Parameter.Value' --output text"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi
if [[ -n "$AWS_REGION" ]]; then
    aws_cmd+=" --region $AWS_REGION"
fi

S3_BUCKET_NAME=$(eval $aws_cmd 2>/dev/null || echo "")

if [[ -z "$S3_BUCKET_NAME" || "$S3_BUCKET_NAME" == "None" ]]; then
    print_error "No se pudo obtener el nombre del bucket S3 desde SSM."
    print_error "Verifica que el parámetro $SSM_BUCKET_PARAM existe y tienes permisos para leerlo."
    print_error "Comando ejecutado: $aws_cmd"
    exit 1
fi

print_info "Bucket S3 obtenido: $S3_BUCKET_NAME"

# ========================================
# 3. COPIAR ARCHIVO OIDC.YAML AL S3
# ========================================

print_section "3. COPIAR ARCHIVO OIDC.YAML AL S3"

print_info "Copiando archivo oidc.yaml al bucket S3..."

# Verificar que el archivo oidc.yaml existe
if [[ ! -f "$OIDC_FILE" ]]; then
    print_error "El archivo oidc.yaml no existe en la ruta: $OIDC_FILE"
    print_info "Verificando estructura de directorios..."
    find . -name "oidc.yaml" 2>/dev/null || print_warning "No se encontró el archivo oidc.yaml"
    exit 1
fi

# Copiar el archivo al S3 con el prefijo /sra-github-oidc/templates/oidc.yaml
aws_cmd="aws s3 cp $OIDC_FILE s3://$S3_BUCKET_NAME/sra-github-oidc/templates/sra-github-oidc-oidc.yaml"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi
if [[ -n "$AWS_REGION" ]]; then
    aws_cmd+=" --region $AWS_REGION"
fi

if eval $aws_cmd; then
    print_info "Archivo oidc.yaml copiado exitosamente al S3 ✓"
else
    print_error "Error al copiar el archivo oidc.yaml al S3"
    exit 1
fi

# ========================================
# 4. OBTENER ORGANIZATION ROOT ID
# ========================================

print_section "4. OBTENER ORGANIZATION ROOT ID"

print_info "Obteniendo Organization Root ID..."
aws_cmd="aws organizations list-roots --query 'Roots[0].Id' --output text"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

ORGANIZATION_ROOT_ID=$(eval $aws_cmd 2>/dev/null)
if [[ -z "$ORGANIZATION_ROOT_ID" || "$ORGANIZATION_ROOT_ID" == "None" ]]; then
    print_error "No se pudo obtener el Organization Root ID automáticamente."
    print_error "Verifica tus credenciales y permisos de AWS CLI."
    print_error "Comando ejecutado: $aws_cmd"
    exit 1
fi
print_info "Organization Root ID obtenido: $ORGANIZATION_ROOT_ID"

# Validar que el Organization Root ID coincide con el parámetro SSM
print_info "Validando Organization Root ID contra parámetro SSM..."

SSM_ROOT_OU_PARAM="/sra/control-tower/root-organizational-unit-id"
aws_cmd="aws ssm get-parameter --name $SSM_ROOT_OU_PARAM --query 'Parameter.Value' --output text"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi
if [[ -n "$AWS_REGION" ]]; then
    aws_cmd+=" --region $AWS_REGION"
fi

SSM_ROOT_OU_ID=$(eval $aws_cmd 2>/dev/null || echo "")

if [[ -n "$SSM_ROOT_OU_ID" && "$SSM_ROOT_OU_ID" != "None" ]]; then
    if [[ "$ORGANIZATION_ROOT_ID" == "$SSM_ROOT_OU_ID" ]]; then
        print_info "✅ Organization Root ID validado correctamente"
    else
        print_warning "⚠️  Organization Root ID no coincide con el parámetro SSM"
        print_warning "  - Obtenido: $ORGANIZATION_ROOT_ID"
        print_warning "  - SSM Parameter: $SSM_ROOT_OU_ID"
        print_warning "  - Se usará el valor del parámetro SSM para el despliegue"
    fi
else
    print_warning "⚠️  No se pudo obtener el parámetro SSM $SSM_ROOT_OU_PARAM"
    print_warning "  - Se usará el valor obtenido directamente: $ORGANIZATION_ROOT_ID"
fi

# ========================================
# 5. VALIDACIÓN DE VARIABLES
# ========================================

print_section "5. VALIDACIÓN DE VARIABLES"

print_info "Configuración:"
echo "  - Stack: $STACK_NAME"
echo "  - Template: $TEMPLATE_FILE"
echo "  - OIDC File: $OIDC_FILE"
echo "  - Organization Root ID: $ORGANIZATION_ROOT_ID"
echo "  - S3 Bucket: $S3_BUCKET_NAME"
echo "  - Profile: $AWS_PROFILE"
echo "  - Región: $AWS_REGION"
echo "  - Rama: $GITHUB_BRANCH"
echo "  - Archivo: $PARAMETERS_FILE"

# ========================================
# 6. VALIDAR PLANTILLA
# ========================================

print_section "6. VALIDAR PLANTILLA"

if [ ! -f "$TEMPLATE_FILE" ]; then
    print_error "Plantilla $TEMPLATE_FILE no encontrada"
    print_info "Verificando estructura de directorios..."
    find . -name "deploy.yaml" 2>/dev/null || print_warning "No se encontró el archivo de template"
    exit 1
fi

print_info "Validando plantilla CloudFormation..."

# Validar sintaxis de la plantilla usando el archivo local
aws_cmd="aws cloudformation validate-template --template-body file://$TEMPLATE_FILE"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

if eval $aws_cmd > /dev/null 2>&1; then
    print_info "Plantilla CloudFormation válida"
else
    print_error "La plantilla CloudFormation no es válida"
    exit 1
fi

print_info "Plantilla validada exitosamente"

# ========================================
# 7. DEPLOY
# ========================================

print_section "7. DEPLOY"

# Realizar deploy
print_info "Iniciando despliegue de GitHub OIDC Solution..."

aws_cmd="aws cloudformation deploy"
aws_cmd+=" --template-file $TEMPLATE_FILE"
aws_cmd+=" --stack-name $STACK_NAME"
aws_cmd+=" --parameter-overrides $GITHUB_OIDC_PARAMS"
aws_cmd+=" --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND"
aws_cmd+=" --region $AWS_REGION"
aws_cmd+=" --no-fail-on-empty-changeset"

if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

if eval $aws_cmd; then
    print_info "Despliegue completado exitosamente"
else
    print_error "Error durante el despliegue"
    exit 1
fi

# ========================================
# 8. REPORTE
# ========================================

print_section "8. REPORTE"

# Verificar estado final del stack
aws_cmd="aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

FINAL_STATUS=$(eval $aws_cmd --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "UNKNOWN")

if [ "$FINAL_STATUS" = "CREATE_COMPLETE" ] || [ "$FINAL_STATUS" = "UPDATE_COMPLETE" ]; then
    print_info "✅ Despliegue de GitHub OIDC Solution completado exitosamente!"
    print_info "Stack: $STACK_NAME"
    print_info "Estado: $FINAL_STATUS"
    print_info "Región: $AWS_REGION"
    print_info "Cuenta: $ACCOUNT_ID"
    print_info "Perfil: $AWS_PROFILE"
    print_info "Rama: $GITHUB_BRANCH"
    print_info "Archivo: $PARAMETERS_FILE"
    
    echo ""
    print_info "Configuración de GitHub OIDC implementada:"
    echo "  ✅ OIDC Provider configurado"
    echo "  ✅ StackSet desplegado"
    echo "  ✅ IAM Role para GitHub Actions creado"
    echo "  ✅ Archivo oidc.yaml subido a S3"
    echo "  ✅ Configuración organization-wide aplicada"
    
    echo ""
    print_info "Para monitorear el progreso del despliegue:"
    echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION --profile $AWS_PROFILE"
    
    echo ""
    print_info "Para verificar el OIDC Provider:"
    echo "aws iam list-open-id-connect-providers --region $AWS_REGION --profile $AWS_PROFILE"
    
    echo ""
    print_info "Para verificar el StackSet:"
    echo "aws cloudformation list-stack-sets --region $AWS_REGION --profile $AWS_PROFILE"
    
    exit 0
else
    print_error "❌ Error durante el despliegue"
    print_error "Estado final del stack: $FINAL_STATUS"
    
    # Mostrar eventos del stack para debugging
    print_info "Últimos eventos del stack:"
    aws_cmd="aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $AWS_REGION --query 'StackEvents[0:5].{Status:ResourceStatus,Reason:ResourceStatusReason,Resource:LogicalResourceId}' --output table"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_cmd+=" --profile $AWS_PROFILE"
    fi
    eval $aws_cmd 2>/dev/null || print_warning "No se pudieron obtener eventos del stack"
    
    exit 1
fi 