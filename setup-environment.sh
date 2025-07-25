#!/bin/bash

# Script para configurar el ambiente de Python para el script de limpieza SRA

set -e

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Función para imprimir mensajes con colores
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Verificar que Python 3 esté instalado
print_step "Verificando instalación de Python 3..."
if ! command -v python3 &> /dev/null; then
    print_error "Python 3 no está instalado. Por favor, instala Python 3.6 o superior."
    exit 1
fi

PYTHON_VERSION=$(python3 --version)
print_message "Python encontrado: $PYTHON_VERSION"

# Verificar que pip esté disponible
print_step "Verificando pip..."
if ! command -v pip &> /dev/null; then
    print_error "pip no está disponible. Por favor, instala pip."
    exit 1
fi

# Crear ambiente virtual
print_step "Creando ambiente virtual..."
if [ -d ".venv" ]; then
    print_warning "El ambiente virtual ya existe. ¿Quieres recrearlo? (y/n)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        print_message "Eliminando ambiente virtual existente..."
        rm -rf .venv
    else
        print_message "Usando ambiente virtual existente..."
    fi
fi

if [ ! -d ".venv" ]; then
    python3 -m venv .venv
    print_message "Ambiente virtual creado: .venv"
fi

# Activar ambiente virtual
print_step "Activando ambiente virtual..."
source .venv/bin/activate

# Verificar que el ambiente virtual esté activo
if [[ "$VIRTUAL_ENV" != *".venv"* ]]; then
    print_error "No se pudo activar el ambiente virtual"
    exit 1
fi

print_message "Ambiente virtual activado: $VIRTUAL_ENV"

# Actualizar pip
print_step "Actualizando pip..."
python -m pip install --upgrade pip

# Instalar dependencias
print_step "Instalando dependencias..."
if [ -f "requirements.txt" ]; then
    print_message "Instalando dependencias desde requirements.txt..."
    pip install -r requirements.txt
else
    print_message "Instalando boto3..."
    pip install boto3
    print_message "Guardando dependencias en requirements.txt..."
    pip freeze > requirements.txt
fi

# Verificar instalación
print_step "Verificando instalación..."
python -c "import boto3; print('✅ boto3 instalado correctamente')"
python -c "import botocore; print('✅ botocore instalado correctamente')"

# Crear script de activación
print_step "Creando script de activación..."
cat > activate-env.sh << 'EOF'
#!/bin/bash
# Script para activar el ambiente virtual de SRA Cleanup

echo "Activando ambiente virtual para SRA Cleanup..."
source .venv/bin/activate

if [[ "$VIRTUAL_ENV" == *".venv"* ]]; then
    echo "✅ Ambiente virtual activado: $VIRTUAL_ENV"
    echo "🐍 Python: $(python --version)"
    echo "📦 boto3: $(python -c 'import boto3; print(boto3.__version__)')"
    echo ""
    echo "Para ejecutar el script de limpieza:"
    echo "python cleanup-sra.py"
    echo ""
    echo "Para desactivar el ambiente:"
    echo "deactivate"
else
    echo "❌ Error al activar el ambiente virtual"
    exit 1
fi
EOF

chmod +x activate-env.sh

# Crear script de desactivación
print_step "Creando script de desactivación..."
cat > deactivate-env.sh << 'EOF'
#!/bin/bash
# Script para desactivar el ambiente virtual de SRA Cleanup

if [[ "$VIRTUAL_ENV" == *".venv"* ]]; then
    deactivate
    echo "✅ Ambiente virtual desactivado"
else
    echo "ℹ️ No hay ambiente virtual activo"
fi
EOF

chmod +x deactivate-env.sh

# Mostrar información final
print_message "✅ Ambiente configurado exitosamente!"
echo ""
echo "📋 Información del ambiente:"
echo "   🐍 Python: $(python --version)"
echo "   📦 boto3: $(python -c 'import boto3; print(boto3.__version__)')"
echo "   📁 Ambiente virtual: $VIRTUAL_ENV"
echo ""
echo "🚀 Comandos útiles:"
echo "   ./activate-env.sh    - Activar el ambiente"
echo "   ./deactivate-env.sh  - Desactivar el ambiente"
echo "   python cleanup-sra.py - Ejecutar script de limpieza"
echo ""
echo "⚠️ IMPORTANTE:"
echo "   - Siempre activa el ambiente antes de ejecutar el script"
echo "   - Renueva los tokens SSO antes de ejecutar:"
echo "     aws sso login --profile yol1-vlf-master-admin"
echo "     aws sso login --profile yol1-vlf-audit-admin"
echo "     aws sso login --profile yol1-vlf-log-admin"
echo ""
print_warning "El ambiente virtual está activo. Para desactivarlo, ejecuta: deactivate" 