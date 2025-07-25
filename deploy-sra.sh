#!/bin/bash

# Script para desplegar AWS SRA con estructura simplificada
# Uso: ./deploy-sra.sh [AWS_PROFILE] [PARAMETERS_FILE]

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
STACK_NAME="sra-security-implementation"

print_info "Stack: $STACK_NAME"

# Extraer parámetros del archivo JSON estructurado
print_info "Extrayendo parámetros del archivo estructurado..."

# Función para extraer parámetros de una sección específica
extract_section_params() {
    local section="$1"
    jq -r --arg section "$section" '.[$section].parameters[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMETERS_FILE" 2>/dev/null || echo ""
}

# Extraer parámetros comunes
COMMON_PARAMS=$(extract_section_params "common")

if [ -z "$COMMON_PARAMS" ]; then
    print_error "No se pudieron extraer parámetros del archivo $PARAMETERS_FILE"
    exit 1
fi

print_info "Parámetros extraídos exitosamente"

# ========================================
# 2. VALIDACIÓN DE VARIABLES
# ========================================

print_section "2. VALIDACIÓN DE VARIABLES"

validar_organization_id() {
    ORG_ID_PARAM=$(jq -r '.common.parameters[] | select(.ParameterKey=="pOrganizationId") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")

    if [[ -z "$ORG_ID_PARAM" ]]; then
        print_error "No se encontró el parámetro pOrganizationId en el archivo $PARAMETERS_FILE"
        exit 1
    fi

    # Obtener el OrganizationId real de AWS Organizations
    aws_cmd="aws organizations describe-organization --query 'Organization.Id' --output text"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_cmd+=" --profile $AWS_PROFILE"
    fi
    ORG_ID_AWS=$(eval $aws_cmd 2>/dev/null || echo "")

    if [[ -z "$ORG_ID_AWS" ]]; then
        print_error "No se pudo obtener el OrganizationId real desde AWS Organizations"
        exit 1
    fi

    if [[ "$ORG_ID_PARAM" != "$ORG_ID_AWS" ]]; then
        print_error "El pOrganizationId del archivo ($ORG_ID_PARAM) no coincide con el OrganizationId real de AWS ($ORG_ID_AWS)"
        exit 1
    fi

    print_info "pOrganizationId validado correctamente: $ORG_ID_PARAM"
}

validar_kms_key_root() {
    # Extraer el ARN del KMS desde los parámetros comunes
    KMS_ARN=$(jq -r '.common.parameters[] | select(.ParameterKey=="pLambdaLogGroupKmsKey") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")

    if [[ -z "$KMS_ARN" ]]; then
        print_error "No se encontró el parámetro pLambdaLogGroupKmsKey en el archivo $PARAMETERS_FILE"
        exit 1
    fi

    # Extraer región y cuenta del ARN
    KMS_REGION=$(echo "$KMS_ARN" | awk -F: '{print $4}')
    KMS_ACCOUNT=$(echo "$KMS_ARN" | awk -F: '{print $5}')

    if [[ -z "$KMS_REGION" || -z "$KMS_ACCOUNT" ]]; then
        print_error "El ARN de la KMS Key no tiene el formato esperado: $KMS_ARN"
        exit 1
    fi

    # Validar que la cuenta sea la root (la misma que ACCOUNT_ID)
    if [[ "$KMS_ACCOUNT" != "$ACCOUNT_ID" ]]; then
        print_error "La KMS Key ($KMS_ARN) no pertenece a la cuenta root actual ($ACCOUNT_ID)"
        exit 1
    fi

    # Validar que la KMS Key exista en la cuenta y región especificada
    aws_cmd="aws kms describe-key --key-id $KMS_ARN --region $KMS_REGION"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_cmd+=" --profile $AWS_PROFILE"
    fi

    if eval $aws_cmd > /dev/null 2>&1; then
        print_info "La KMS Key existe y pertenece a la cuenta root: $KMS_ARN"
    else
        print_error "La KMS Key $KMS_ARN no existe o no es accesible en la cuenta root"
        exit 1
    fi
}

validar_cuentas_ids() {
    # Extraer los IDs de cuenta desde los parámetros comunes
    SECURITY_ACCOUNT_ID=$(jq -r '.common.parameters[] | select(.ParameterKey=="pSecurityAccountId") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")
    LOG_ARCHIVE_ACCOUNT_ID=$(jq -r '.common.parameters[] | select(.ParameterKey=="pLogArchiveAccountId") | .ParameterValue' "$PARAMETERS_FILE" 2>/dev/null || echo "")

    if [[ -z "$SECURITY_ACCOUNT_ID" ]]; then
        print_error "No se encontró el parámetro pSecurityAccountId en el archivo $PARAMETERS_FILE"
        exit 1
    fi

    if [[ -z "$LOG_ARCHIVE_ACCOUNT_ID" ]]; then
        print_error "No se encontró el parámetro pLogArchiveAccountId en el archivo $PARAMETERS_FILE"
        exit 1
    fi

    # Validar que los IDs tengan 12 dígitos numéricos
    if ! [[ "$SECURITY_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        print_error "El pSecurityAccountId ($SECURITY_ACCOUNT_ID) no es un ID de cuenta válido (debe tener 12 dígitos numéricos)"
        exit 1
    fi

    if ! [[ "$LOG_ARCHIVE_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        print_error "El pLogArchiveAccountId ($LOG_ARCHIVE_ACCOUNT_ID) no es un ID de cuenta válido (debe tener 12 dígitos numéricos)"
        exit 1
    fi

    # Validar contra Control Tower que existan las cuentas log y audit con esos IDs
    print_info "Validando existencia de cuentas log y audit en Control Tower..."

    # Obtener información de la landing zone de Control Tower
    aws_cmd="aws controltower list-landing-zones --region $AWS_REGION"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_cmd+=" --profile $AWS_PROFILE"
    fi

    LANDING_ZONES_JSON=$(eval $aws_cmd 2>/dev/null)
    if [[ -z "$LANDING_ZONES_JSON" ]]; then
        print_error "No se pudo obtener la lista de landing zones de Control Tower"
        exit 1
    fi

    # Obtener el ID de la primera landing zone (asumiendo que solo hay una)
    LANDING_ZONE_ID=$(echo "$LANDING_ZONES_JSON" | jq -r '.landingZones[0].landingZoneId' 2>/dev/null || echo "")
    if [[ -z "$LANDING_ZONE_ID" ]]; then
        print_error "No se pudo obtener el ID de la landing zone de Control Tower"
        exit 1
    fi

    # Obtener detalles de la landing zone
    aws_cmd="aws controltower get-landing-zone --landing-zone-identifier $LANDING_ZONE_ID --region $AWS_REGION"
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_cmd+=" --profile $AWS_PROFILE"
    fi

    LANDING_ZONE_DETAILS=$(eval $aws_cmd 2>/dev/null)
    if [[ -z "$LANDING_ZONE_DETAILS" ]]; then
        print_error "No se pudo obtener los detalles de la landing zone de Control Tower"
        exit 1
    fi

    # Extraer información de las cuentas gestionadas desde los detalles de la landing zone
    LOG_ACCOUNT_FOUND=$(echo "$LANDING_ZONE_DETAILS" | jq -r --arg id "$LOG_ARCHIVE_ACCOUNT_ID" '.landingZone.managedAccounts[] | select(.accountId==$id and (.accountType=="LOG_ARCHIVE" or .accountName|test("log"; "i"))) | .accountId' 2>/dev/null || echo "")
    AUDIT_ACCOUNT_FOUND=$(echo "$LANDING_ZONE_DETAILS" | jq -r --arg id "$SECURITY_ACCOUNT_ID" '.landingZone.managedAccounts[] | select(.accountId==$id and (.accountType=="AUDIT" or .accountName|test("audit"; "i"))) | .accountId' 2>/dev/null || echo "")

    if [[ -z "$LOG_ACCOUNT_FOUND" ]]; then
        print_error "No se encontró una cuenta LOG ARCHIVE en Control Tower con el ID $LOG_ARCHIVE_ACCOUNT_ID"
        exit 1
    fi

    if [[ -z "$AUDIT_ACCOUNT_FOUND" ]]; then
        print_error "No se encontró una cuenta AUDIT en Control Tower con el ID $SECURITY_ACCOUNT_ID"
        exit 1
    fi

    # Validar que los IDs extraídos coincidan exactamente con los encontrados en Control Tower
    if [[ "$LOG_ACCOUNT_FOUND" != "$LOG_ARCHIVE_ACCOUNT_ID" ]]; then
        print_error "El ID de la cuenta LOG ARCHIVE extraído ($LOG_ARCHIVE_ACCOUNT_ID) no coincide con el encontrado en Control Tower ($LOG_ACCOUNT_FOUND)"
        exit 1
    fi

    if [[ "$AUDIT_ACCOUNT_FOUND" != "$SECURITY_ACCOUNT_ID" ]]; then
        print_error "El ID de la cuenta AUDIT extraído ($SECURITY_ACCOUNT_ID) no coincide con el encontrado en Control Tower ($AUDIT_ACCOUNT_FOUND)"
        exit 1
    fi

    print_info "Los IDs de cuentas LOG ARCHIVE y AUDIT coinciden correctamente con los de Control Tower."
}

validar_repo_y_rama() {
    print_section "Validando repositorio y rama remotos"

    # Extraer URL y rama esperadas del archivo de parámetros
    REPO_URL_ESPERADO=$(jq -r '.common.parameters[] | select(.ParameterKey=="pRepoURL") | .ParameterValue' "$PARAMETERS_FILE")
    REPO_BRANCH_ESPERADO=$(jq -r '.common.parameters[] | select(.ParameterKey=="pRepoBranch") | .ParameterValue' "$PARAMETERS_FILE")

    # Obtener URL y rama actuales del repositorio local
    REPO_URL_ACTUAL=$(git config --get remote.origin.url 2>/dev/null || echo "")
    REPO_BRANCH_ACTUAL=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    if [[ -z "$REPO_URL_ACTUAL" ]]; then
        print_error "No se pudo obtener la URL del repositorio remoto actual."
        exit 1
    fi

    if [[ -z "$REPO_BRANCH_ACTUAL" ]]; then
        print_error "No se pudo obtener la rama actual del repositorio."
        exit 1
    fi

    # Validar URL del repositorio
    if [[ "$REPO_URL_ACTUAL" != "$REPO_URL_ESPERADO" ]]; then
        print_error "La URL del repositorio remoto ($REPO_URL_ACTUAL) no coincide con la esperada ($REPO_URL_ESPERADO) según el archivo de parámetros."
        exit 1
    fi

    # Validar rama
    if [[ "$REPO_BRANCH_ACTUAL" != "$REPO_BRANCH_ESPERADO" ]]; then
        print_error "La rama actual ($REPO_BRANCH_ACTUAL) no coincide con la esperada ($REPO_BRANCH_ESPERADO) según el archivo de parámetros."
        exit 1
    fi

    print_info "El repositorio remoto y la rama coinciden con la información del archivo de parámetros."
}

# Llamar a la función para validar el repositorio y la rama
validar_repo_y_rama

# Llamar a la función para validar los IDs de cuentas
# validar_cuentas_ids

# Llamar a la función para validar el OrganizationId
validar_organization_id

# Llamar a la función para validar la KMS Key
validar_kms_key_root

# ========================================
# 3. VALIDAR PLANTILLA
# ========================================

print_section "3. VALIDAR PLANTILLA"
TEMPLATE_FILE="aws_sra/easy_setup/templates/sra-easy-setup.yaml"

if [ ! -f "$TEMPLATE_FILE" ]; then
    print_error "Plantilla $TEMPLATE_FILE no encontrada"
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
print_info "Iniciando despliegue..."

aws_cmd="aws cloudformation deploy"
aws_cmd+=" --template-file $TEMPLATE_FILE"
aws_cmd+=" --stack-name $STACK_NAME"
aws_cmd+=" --parameter-overrides $COMMON_PARAMS"
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
    print_info "✅ Despliegue completado exitosamente!"
    print_info "Stack: $STACK_NAME"
    print_info "Estado: $FINAL_STATUS"
    print_info "Región: $AWS_REGION"
    print_info "Cuenta: $ACCOUNT_ID"
    print_info "Perfil: $AWS_PROFILE"
    print_info "Rama: $GITHUB_BRANCH"
    print_info "Archivo: $PARAMETERS_FILE"
    
    echo ""
    print_info "Soluciones implementadas:"
    
    # Listar soluciones activas
    for section in rAccountAlternateContactsSolutionStack rCloudTrailSolutionStack rConfigManagementSolutionStack rConfigConformancePackSolutionStack rDetectiveSolutionStack rEC2DefaultEBSEncryptionSolutionStack rFirewallManagerSolutionStack rGuardDutySolutionStack rIAMAccessAnalyzerSolutionStack rIAMPasswordPolicySolutionStack rMacieSolutionStack rS3BlockAccountPublicAccessSolutionStack rSecurityHubSolutionStack rShieldSolutionStack rInspectorSolutionStack rPatchMgrSolutionStack; do
        if jq -e --arg section "$section" '.[$section].parameters[] | select(.ParameterKey | test("^pDeploy.*Solution$")) | select(.ParameterValue == "Yes")' "$PARAMETERS_FILE" >/dev/null 2>&1; then
            echo "  ✅ $(echo $section | sed 's/r//' | sed 's/SolutionStack//')"
        fi
    done
    
    echo ""
    print_info "Para monitorear el progreso del despliegue:"
    echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --region $AWS_REGION --profile $AWS_PROFILE"
    
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