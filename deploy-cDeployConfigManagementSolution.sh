#!/bin/bash

# Script para desplegar AWS SRA Config Management Solution
# Uso: ./deploy-cDeployConfigManagementSolution.sh [AWS_PROFILE] [PARAMETERS_FILE]

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
STACK_NAME="sra-config-management-account-solution"
TEMPLATE_FILE="aws_sra/solutions/config/config_management_account/templates/sra-config-management-account-main-ssm.yaml"

print_info "Stack: $STACK_NAME"
print_info "Template: $TEMPLATE_FILE"

# Extraer parámetros específicos de Config Management
print_info "Extrayendo parámetros de Config Management..."

# Función para extraer parámetros de una sección específica
extract_section_params() {
    local section="$1"
    jq -r --arg section "$section" '.[$section].parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMETERS_FILE" 2>/dev/null || echo ""
}

# Extraer parámetros de Config Management
CONFIG_MANAGEMENT_PARAMS=$(extract_section_params "rConfigManagementSolutionStack")

if [ -z "$CONFIG_MANAGEMENT_PARAMS" ]; then
    print_error "No se pudieron extraer parámetros de Config Management del archivo $PARAMETERS_FILE"
    exit 1
fi

print_info "Parámetros extraídos para el despliegue:"
echo "$CONFIG_MANAGEMENT_PARAMS"

# Convertir los parámetros a formato para CloudFormation deploy
CONFIG_MANAGEMENT_PARAMS=$(echo "$CONFIG_MANAGEMENT_PARAMS" | tr '\n' ' ')

if [ -z "$CONFIG_MANAGEMENT_PARAMS" ]; then
    print_error "No se pudieron extraer parámetros de Config Management del archivo $PARAMETERS_FILE"
    exit 1
fi

print_info "Parámetros de Config Management extraídos exitosamente"

# ========================================
# 2. VALIDACIÓN DE VARIABLES
# ========================================

print_section "2. VALIDACIÓN DE VARIABLES"

# ========================================
# 3. VALIDAR PLANTILLA
# ========================================

print_section "3. VALIDAR PLANTILLA"

if [ ! -f "$TEMPLATE_FILE" ]; then
    print_error "Plantilla $TEMPLATE_FILE no encontrada"
    print_info "Verificando estructura de directorios..."
    find . -name "sra-config-management-account-main-ssm.yaml" 2>/dev/null || print_warning "No se encontró el archivo de template"
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
# 4. DEPLOY
# ========================================

print_section "4. DEPLOY"

# Realizar deploy
print_info "Iniciando despliegue de Config Management Solution..."

aws_cmd="aws cloudformation deploy"
aws_cmd+=" --template-file $TEMPLATE_FILE"
aws_cmd+=" --stack-name $STACK_NAME"
aws_cmd+=" --parameter-overrides $CONFIG_MANAGEMENT_PARAMS"
aws_cmd+=" --capabilities CAPABILITY_NAMED_IAM"
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
# 5. REPORTE
# ========================================

print_section "5. REPORTE"

# Verificar estado final del stack
aws_cmd="aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

FINAL_STATUS=$(eval $aws_cmd --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "UNKNOWN")

if [ "$FINAL_STATUS" = "CREATE_COMPLETE" ] || [ "$FINAL_STATUS" = "UPDATE_COMPLETE" ]; then
    print_info "✅ Despliegue de Config Management completado exitosamente!"
    print_info "Stack: $STACK_NAME"
    print_info "Estado: $FINAL_STATUS"
    print_info "Región: $AWS_REGION"
    print_info "Cuenta: $ACCOUNT_ID"
    print_info "Perfil: $AWS_PROFILE"
    print_info "Rama: $GITHUB_BRANCH"
    print_info "Archivo: $PARAMETERS_FILE"
    
    echo ""
    print_info "Configuración de Config Management implementada:"
    echo "  ✅ AWS Config habilitado en la cuenta de gestión"
    echo "  ✅ Recorder configurado para todos los recursos soportados"
    echo "  ✅ Canal de entrega configurado"
    echo "  ✅ Agregador actualizado en la cuenta de auditoría"
    echo "  ✅ Logs de Lambda configurados"
    
    echo ""
    print_info "Para monitorear el progreso del despliegue:"
    echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION --profile $AWS_PROFILE"
    
    echo ""
    print_info "Para verificar la configuración de AWS Config:"
    echo "aws configservice describe-configuration-recorders --region $AWS_REGION --profile $AWS_PROFILE"
    echo "aws configservice describe-delivery-channels --region $AWS_REGION --profile $AWS_PROFILE"
    
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