#!/bin/bash

# Script para sincronizar lambdas de Batch Account Creation al bucket SRA
# Uso: ./sync_lambdas.sh [AWS_PROFILE]

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
# 1. CONFIGURACIÓN
# ========================================

print_section "1. CONFIGURACIÓN"

# Parámetros de la solución SRA
SRASolutionName="sra-batch-account-creation"
SRAStagingS3BucketName="/sra/staging-s3-bucket-name"

# Obtener el bucket real desde SSM Parameter Store
AWS_PROFILE=${1:-""}

if [[ -n "$AWS_PROFILE" ]]; then
    BUCKET_NAME=$(aws ssm get-parameter --name "$SRAStagingS3BucketName" --profile "$AWS_PROFILE" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
else
    BUCKET_NAME=$(aws ssm get-parameter --name "$SRAStagingS3BucketName" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
fi

if [[ -z "$BUCKET_NAME" ]]; then
    print_error "No se pudo obtener el nombre del bucket desde SSM Parameter Store"
    print_info "Verificando parámetros disponibles..."
    if [[ -n "$AWS_PROFILE" ]]; then
        aws ssm describe-parameters --profile "$AWS_PROFILE" --query 'Parameters[?contains(Name, `staging-s3-bucket`)].Name' --output table 2>/dev/null || print_warning "No se pudieron listar parámetros"
    else
        aws ssm describe-parameters --query 'Parameters[?contains(Name, `staging-s3-bucket`)].Name' --output table 2>/dev/null || print_warning "No se pudieron listar parámetros"
    fi
    exit 1
fi

print_info "Solución SRA: $SRASolutionName"
print_info "Bucket S3: $BUCKET_NAME"
print_info "Perfil AWS: $AWS_PROFILE"

# ========================================
# 2. VALIDACIÓN DE ARCHIVOS
# ========================================

print_section "2. VALIDACIÓN DE ARCHIVOS"

# aws_sra/solutions/account/batch_account_creation/lambda/src
# Definir la ruta donde se encuentran los archivos Python
LAMBDA_SRC_DIR="aws_sra/solutions/account/batch_account_creation/lambda/src"

# Verificar que el directorio existe
if [[ ! -d "$LAMBDA_SRC_DIR" ]]; then
    print_error "Directorio $LAMBDA_SRC_DIR no encontrado"
    print_info "Verificando estructura de directorios..."
    find . -name "lambda" -type d 2>/dev/null || print_warning "No se encontró directorio lambda"
    exit 1
fi

print_info "Directorio de archivos Lambda: $LAMBDA_SRC_DIR"

# Verificar que los archivos Python existan
PYTHON_FILES=("new_account_handler.py" "account_create.py" "cfnresource.py")

for file in "${PYTHON_FILES[@]}"; do
    if [[ ! -f "$LAMBDA_SRC_DIR/$file" ]]; then
        print_error "Archivo $file no encontrado en $LAMBDA_SRC_DIR"
        print_info "Archivos disponibles en $LAMBDA_SRC_DIR:"
        ls -la "$LAMBDA_SRC_DIR"/*.py 2>/dev/null || print_warning "No se encontraron archivos Python en $LAMBDA_SRC_DIR"
        exit 1
    fi
done

print_info "Todos los archivos Python encontrados"

# ========================================
# 3. ANÁLISIS DE CÓDIGO
# ========================================

print_section "3. ANÁLISIS DE CÓDIGO"

echo
echo "new_account_handler.py"
echo "======================"
if command -v pylint &> /dev/null; then
    pylint "$LAMBDA_SRC_DIR/new_account_handler.py" 2>/dev/null | grep '^Your code has been rated' || print_warning "pylint no disponible o no encontró problemas"
else
    print_warning "pylint no está instalado"
fi

echo
echo "account_create.py"
echo "================="
if command -v pylint &> /dev/null; then
    pylint "$LAMBDA_SRC_DIR/account_create.py" 2>/dev/null | grep '^Your code has been rated' || print_warning "pylint no disponible o no encontró problemas"
else
    print_warning "pylint no está instalado"
fi

# ========================================
# 4. EMPAQUETADO
# ========================================

print_section "4. EMPAQUETADO"

print_info "Creando archivos ZIP..."

# Crear directorio temporal para el empaquetado
TEMP_DIR=$(mktemp -d)
print_info "Directorio temporal: $TEMP_DIR"

# Empaquetar new_account_handler
print_info "Empaquetando new_account_handler..."
cp "$LAMBDA_SRC_DIR/new_account_handler.py" "$TEMP_DIR/"
cp "$LAMBDA_SRC_DIR/cfnresource.py" "$TEMP_DIR/"
cd "$TEMP_DIR"
zip -r ct_batchcreation_lambda.zip new_account_handler.py cfnresource.py
cd - > /dev/null

# Empaquetar account_create
print_info "Empaquetando account_create..."
cp "$LAMBDA_SRC_DIR/account_create.py" "$TEMP_DIR/"
cp "$LAMBDA_SRC_DIR/cfnresource.py" "$TEMP_DIR/"
cd "$TEMP_DIR"
zip -r ct_account_create_lambda.zip account_create.py cfnresource.py
cd - > /dev/null

print_info "Archivos ZIP creados exitosamente"

# ========================================
# 5. SUBIDA A S3
# ========================================

print_section "5. SUBIDA A S3"

# Verificar que el bucket existe
aws_cmd="aws s3 ls s3://$BUCKET_NAME"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

if ! eval $aws_cmd &> /dev/null; then
    print_error "El bucket $BUCKET_NAME no existe o no tienes permisos para acceder"
    exit 1
fi

print_info "Bucket $BUCKET_NAME verificado"

# Crear estructura de directorios en S3
S3_PREFIX="$SRASolutionName/lambda_code"

print_info "Subiendo archivos a s3://$BUCKET_NAME/$S3_PREFIX/"

# Subir archivos ZIP
aws_cmd="aws s3 cp $TEMP_DIR/ct_batchcreation_lambda.zip s3://$BUCKET_NAME/$S3_PREFIX/ct_batchcreation_lambda.zip"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

if eval $aws_cmd; then
    print_info "✅ ct_batchcreation_lambda.zip subido exitosamente"
else
    print_error "❌ Error al subir ct_batchcreation_lambda.zip"
    exit 1
fi

aws_cmd="aws s3 cp $TEMP_DIR/ct_account_create_lambda.zip s3://$BUCKET_NAME/$S3_PREFIX/ct_account_create_lambda.zip"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

if eval $aws_cmd; then
    print_info "✅ ct_account_create_lambda.zip subido exitosamente"
else
    print_error "❌ Error al subir ct_account_create_lambda.zip"
    exit 1
fi

# ========================================
# 6. LIMPIEZA Y VERIFICACIÓN
# ========================================

print_section "6. LIMPIEZA Y VERIFICACIÓN"

# Limpiar directorio temporal
rm -rf "$TEMP_DIR"
print_info "Directorio temporal eliminado"

# Verificar que los archivos estén en S3
print_info "Verificando archivos en S3..."

aws_cmd="aws s3 ls s3://$BUCKET_NAME/$S3_PREFIX/"
if [[ -n "$AWS_PROFILE" ]]; then
    aws_cmd+=" --profile $AWS_PROFILE"
fi

S3_FILES=$(eval $aws_cmd 2>/dev/null || echo "")

if echo "$S3_FILES" | grep -q "ct_batchcreation_lambda.zip" && echo "$S3_FILES" | grep -q "ct_account_create_lambda.zip"; then
    print_info "✅ Todos los archivos verificados en S3"
else
    print_error "❌ No se pudieron verificar todos los archivos en S3"
    exit 1
fi

# ========================================
# 7. REPORTE FINAL
# ========================================

print_section "7. REPORTE FINAL"

print_info "✅ Sincronización completada exitosamente!"
print_info "Solución: $SRASolutionName"
print_info "Bucket: $BUCKET_NAME"
print_info "Ruta: s3://$BUCKET_NAME/$S3_PREFIX/"
print_info "Archivos subidos:"
echo "  - ct_batchcreation_lambda.zip"
echo "  - ct_account_create_lambda.zip"

echo ""
print_info "Para verificar los archivos:"
echo "aws s3 ls s3://$BUCKET_NAME/$S3_PREFIX/ --profile $AWS_PROFILE"

echo ""
print_info "Para descargar un archivo:"
echo "aws s3 cp s3://$BUCKET_NAME/$S3_PREFIX/ct_batchcreation_lambda.zip . --profile $AWS_PROFILE"

echo ""
print_info "Ahora puedes desplegar la solución usando:"
echo "./deploy-cDeployBatchAccountCreationSolution.sh $AWS_PROFILE"

exit 0
