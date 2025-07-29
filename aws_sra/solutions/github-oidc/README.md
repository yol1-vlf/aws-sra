# OIDC Provider Deployment

Este directorio contiene la implementación del OIDC Provider para GitHub Actions en AWS Control Tower con integración S3.

## 📁 Archivos

- `deploy.yaml` - Plantilla principal de despliegue con parámetros S3
- `oidc.yaml` - Plantilla del OIDC Provider y IAM Role
- `deploy.sh` - Script de despliegue automatizado con S3
- `README.md` - Este archivo de documentación

## 🚀 Uso

### Despliegue Básico
```bash
./deploy.sh <organizacion-github> <repositorio-github>
```

### Con Perfil AWS
```bash
./deploy.sh <organizacion-github> <repositorio-github> <perfil-aws>
```

### Con Región Específica
```bash
./deploy.sh <organizacion-github> <repositorio-github> <perfil-aws> <region-aws>
```

## 📋 Ejemplos

```bash
# Despliegue básico
./deploy.sh mi-organizacion mi-repositorio

# Con perfil de producción
./deploy.sh mi-org mi-repo production

# Con región específica
./deploy.sh mi-org mi-repo production us-west-2
```

## ⚙️ Configuración

### Parámetros Requeridos
- `organizacion-github` - Nombre de la organización de GitHub
- `repositorio-github` - Nombre del repositorio de GitHub

### Parámetros Opcionales
- `perfil-aws` - Perfil de AWS CLI (default: sin perfil)
- `region-aws` - Región de AWS (default: us-east-1)

### Valores por Defecto
- Stack Name: `sra-aws-oidc`
- Role Name: `github-actions-role`
- Session Duration: `3600` segundos
- Target Region: `us-east-1` (Virginia)
- S3 Template Path: `/oidc/oidc.yaml`

## 🔄 Proceso de Despliegue

El script automatiza completamente el proceso:

1. **Lee el bucket S3** desde el parámetro SSM `/sra/devops-iac-base-s3-bucket-name`
2. **Copia el template** `oidc.yaml` al bucket S3 con la ruta `/oidc/oidc.yaml`
3. **Obtiene automáticamente** el Organization Root ID
4. **Despliega** el stack y StackSet usando las plantillas del S3

### ⚠️ Dependencias Requeridas

**IMPORTANTE**: Antes de ejecutar el despliegue, asegúrate de que:

1. **El stack de S3 esté desplegado** (03-IaCBase):
```bash
# Verificar que el parámetro SSM existe
aws ssm get-parameter --name /sra/devops-iac-base-s3-bucket-name --region us-east-1
```

2. **Tengas permisos** para:
   - Leer parámetros SSM
   - Escribir en el bucket S3
   - Desplegar CloudFormation
   - Acceder a AWS Organizations

## 🏗️ Recursos Creados

### Stack Principal
- **OIDC Provider** - Para autenticación de GitHub Actions
- **IAM Role** - Con permisos para CloudFormation y logs

### StackSet Organizacional
- **StackSet** - Para despliegue automático en todas las cuentas
- **Stack Instances** - Instancias en cada cuenta de la organización

### Recursos S3
- **Template almacenado** en `/oidc/oidc.yaml`
- **URL dinámica** basada en el bucket y región

## 📊 Outputs

- `OIDCStackName` - Nombre del stack OIDC
- `OIDCStackSetName` - Nombre del StackSet
- `DeploymentStatus` - Estado del despliegue organizacional

## 🔧 Requisitos Previos

### Infraestructura
- ✅ Stack de S3 desplegado (03-IaCBase)
- ✅ Parámetro SSM `/sra/devops-iac-base-s3-bucket-name` configurado
- ✅ Control Tower habilitado
- ✅ AWS Organizations configurado

### Permisos AWS
- `ssm:GetParameter` - Para leer el nombre del bucket
- `s3:PutObject` - Para copiar el template al S3
- `cloudformation:*` - Para desplegar stacks
- `organizations:ListRoots` - Para obtener el Organization Root ID
- `iam:*` - Para crear roles y providers

### Herramientas
- AWS CLI v2.x o superior
- Credenciales configuradas con permisos de administrador

## 🛡️ Seguridad

### OIDC Provider
- ✅ Solo permite autenticación desde repositorios específicos
- ✅ Thumbprints oficiales de GitHub
- ✅ Condiciones de seguridad estrictas

### IAM Role
- ✅ Permisos mínimos necesarios
- ✅ Política de confianza restringida
- ✅ Duración de sesión configurable

### S3 Integration
- ✅ Template almacenado de forma segura
- ✅ Acceso controlado por políticas de bucket
- ✅ Encriptación habilitada

### Tags Organizacionales
- ✅ Tags estándar SRA aplicados
- ✅ Trazabilidad completa
- ✅ Cumplimiento organizacional

## 🔍 Verificación

### Verificar el Despliegue
```bash
# Verificar el stack
aws cloudformation describe-stacks --stack-name sra-aws-oidc

# Verificar el StackSet
aws cloudformation list-stack-sets --query 'StackSets[?StackSetName==`sra-aws-oidc-stackset`]'

# Verificar el template en S3
aws s3 ls s3://$(aws ssm get-parameter --name /sra/devops-iac-base-s3-bucket-name --query 'Parameter.Value' --output text)/oidc/
```

### Verificar el OIDC Provider
```bash
# Listar providers OIDC
aws iam list-open-id-connect-providers

# Verificar el rol creado
aws iam get-role --role-name sra-aws-ctautomation-github-actions-role
```

## 🚨 Troubleshooting

### Error: "No se pudo obtener el nombre del bucket S3"
- Verifica que el stack 03-IaCBase esté desplegado
- Confirma que el parámetro SSM existe y tienes permisos para leerlo

### Error: "Error al copiar el archivo oidc.yaml al S3"
- Verifica permisos de escritura en el bucket S3
- Confirma que el archivo oidc.yaml existe en el directorio

### Error: "No se pudo obtener el Organization Root ID"
- Verifica credenciales y permisos de AWS Organizations
- Confirma que tienes acceso a la organización

### Error: "Error durante el despliegue"
- Revisa los logs de CloudFormation en la consola
- Verifica que todos los parámetros sean válidos
- Confirma que el template en S3 sea accesible

## 📝 Notas Importantes

1. **El script es completamente automatizado** - No requiere configuración manual
2. **Usa el bucket S3 como repositorio central** - Mejora la seguridad y control de versiones
3. **Despliegue organizacional** - Se aplica automáticamente a todas las cuentas
4. **Rollback automático** - CloudFormation maneja la reversión en caso de error
5. **Logs de auditoría** - Todas las acciones quedan registradas en CloudTrail 