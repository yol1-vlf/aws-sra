#!/usr/bin/env python3
"""
Script para limpiar todos los recursos relacionados con AWS SRA
Conecta a las cuentas master, audit y log usando los perfiles especificados

Uso:
    python cleanup-sra.py          # Modo dry run - solo revisa recursos
    python cleanup-sra.py --delete # Modo eliminación - elimina recursos
"""

import boto3
import botocore
import json
import time
import sys
import argparse
from botocore.exceptions import ClientError, NoCredentialsError
import logging
from collections import defaultdict

# Configurar logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuración de perfiles y cuentas
ACCOUNTS = {
    'master': {
        'profile': 'aws-sso-dev-root',
        'name': 'Master Account'
    },
    'audit': {
        'profile': 'aws-sso-dev-audit', 
        'name': 'Audit Account'
    },
    'log': {
        'profile': 'aws-sso-dev-log',
        'name': 'Log Archive Account'
    }
}

# Regiones donde SRA se despliega típicamente
SRA_REGIONS = [
    'us-east-1',    # Virginia (región principal)
    'us-west-2'     # Oregon (región secundaria)
]

# Estructura para almacenar errores y reportes
class CleanupReport:
    def __init__(self):
        self.errors = defaultdict(list)
        self.successes = defaultdict(list)
        self.resources_found = defaultdict(dict)
        self.resources_deleted = defaultdict(dict)
    
    def add_error(self, account_name, resource_type, resource_name, error_msg, region=None):
        """Agregar un error al reporte"""
        key = f"{account_name} ({region})" if region else account_name
        self.errors[key].append({
            'resource_type': resource_type,
            'resource_name': resource_name,
            'error': str(error_msg),
            'region': region
        })
    
    def add_success(self, account_name, resource_type, resource_name, region=None):
        """Agregar un éxito al reporte"""
        key = f"{account_name} ({region})" if region else account_name
        self.successes[key].append({
            'resource_type': resource_type,
            'resource_name': resource_name,
            'region': region
        })
    
    def add_resource_found(self, account_name, resource_type, count, region=None):
        """Agregar recursos encontrados"""
        key = f"{account_name} ({region})" if region else account_name
        if key not in self.resources_found:
            self.resources_found[key] = {}
        self.resources_found[key][resource_type] = count
    
    def add_resource_deleted(self, account_name, resource_type, count, region=None):
        """Agregar recursos eliminados"""
        key = f"{account_name} ({region})" if region else account_name
        if key not in self.resources_deleted:
            self.resources_deleted[key] = {}
        self.resources_deleted[key][resource_type] = count
    
    def print_summary(self, delete_mode=False):
        """Imprimir resumen del reporte"""
        logger.info(f"\n{'='*80}")
        logger.info("REPORTE DETALLADO DE LIMPIEZA SRA")
        logger.info(f"{'='*80}")
        
        # Mostrar recursos encontrados
        if self.resources_found:
            logger.info("\n📊 RECURSOS ENCONTRADOS:")
            for account_key, resources in self.resources_found.items():
                logger.info(f"\n  {account_key}:")
                for resource_type, count in resources.items():
                    logger.info(f"    - {resource_type}: {count}")
        
        # Mostrar recursos eliminados (solo en modo delete)
        if delete_mode and self.resources_deleted:
            logger.info("\n🗑️ RECURSOS ELIMINADOS:")
            for account_key, resources in self.resources_deleted.items():
                logger.info(f"\n  {account_key}:")
                for resource_type, count in resources.items():
                    logger.info(f"    - {resource_type}: {count}")
        
        # Mostrar éxitos
        if self.successes:
            logger.info("\n✅ OPERACIONES EXITOSAS:")
            for account_key, successes in self.successes.items():
                logger.info(f"\n  {account_key}:")
                for success in successes:
                    region_info = f" ({success['region']})" if success['region'] else ""
                    logger.info(f"    - {success['resource_type']}: {success['resource_name']}{region_info}")
        
        # Mostrar errores
        if self.errors:
            logger.info("\n❌ ERRORES ENCONTRADOS:")
            for account_key, errors in self.errors.items():
                logger.info(f"\n  {account_key}:")
                for error in errors:
                    region_info = f" ({error['region']})" if error['region'] else ""
                    logger.info(f"    - {error['resource_type']}: {error['resource_name']}{region_info}")
                    logger.info(f"      Error: {error['error']}")
        
        # Resumen final
        total_errors = sum(len(errors) for errors in self.errors.values())
        total_successes = sum(len(successes) for successes in self.successes.values())
        
        logger.info(f"\n📈 RESUMEN FINAL:")
        logger.info(f"  - Operaciones exitosas: {total_successes}")
        logger.info(f"  - Errores encontrados: {total_errors}")
        
        if total_errors > 0:
            logger.warning(f"\n⚠️ Se encontraron {total_errors} errores durante la ejecución.")
            logger.warning("Revisa los errores anteriores para más detalles.")
        else:
            logger.info(f"\n✅ Todas las operaciones se completaron exitosamente.")

# Variable global para el reporte
cleanup_report = CleanupReport()

def parse_arguments():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(
        description='Script para limpiar recursos AWS SRA',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos:
  python cleanup-sra.py          # Modo dry run - solo revisa recursos
  python cleanup-sra.py --delete # Modo eliminación - elimina recursos
        """
    )
    parser.add_argument(
        '--delete',
        action='store_true',
        help='Eliminar recursos encontrados (sin este parámetro solo se revisan)'
    )
    return parser.parse_args()

def get_session(profile_name):
    """Crear sesión AWS con el perfil especificado"""
    try:
        session = boto3.Session(profile_name=profile_name)
        # Verificar que las credenciales funcionen
        sts = session.client('sts')
        identity = sts.get_caller_identity()
        logger.info(f"Conectado a cuenta: {identity['Account']} usando perfil: {profile_name}")
        return session
    except NoCredentialsError:
        logger.error(f"No se encontraron credenciales para el perfil: {profile_name}")
        return None
    except ClientError as e:
        logger.error(f"Error al conectar con perfil {profile_name}: {e}")
        return None

def list_cloudformation_stacks(session, account_name, delete_mode=False):
    """Listar o eliminar stacks de CloudFormation relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando stacks de CloudFormation en {account_name}...")
    else:
        logger.info(f"Revisando stacks de CloudFormation en {account_name}...")
    
    all_sra_stacks = []
    
    # Procesar cada región
    for region in SRA_REGIONS:
        try:
            cf_client = session.client('cloudformation', region_name=region)
            
            # Buscar stacks que contengan 'sra' en el nombre
            response = cf_client.list_stacks(StackStatusFilter=[
                'CREATE_COMPLETE', 'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE',
                'CREATE_FAILED', 'DELETE_FAILED', 'ROLLBACK_COMPLETE'
            ])
            
            region_stacks = []
            for stack in response['StackSummaries']:
                if 'sra' in stack['StackName'].lower():
                    region_stacks.append({'name': stack['StackName'], 'region': region})
            
            if region_stacks:
                logger.info(f"Encontrados {len(region_stacks)} stacks SRA en {account_name} ({region})")
                all_sra_stacks.extend(region_stacks)
                cleanup_report.add_resource_found(account_name, "CloudFormation Stacks", len(region_stacks), region)
            
        except ClientError as e:
            error_msg = f"Error al listar stacks en {account_name} ({region}): {e}"
            logger.error(error_msg)
            cleanup_report.add_error(account_name, "CloudFormation Stacks", "listado", e, region)
    
    if not all_sra_stacks:
        logger.info(f"No se encontraron stacks SRA en {account_name}")
        return
    
    logger.info(f"Total: {len(all_sra_stacks)} stacks SRA encontrados en {account_name}")
    
    if delete_mode:
        deleted_count = 0
        for stack_info in all_sra_stacks:
            try:
                stack_name = stack_info['name']
                region = stack_info['region']
                cf_client = session.client('cloudformation', region_name=region)
                
                logger.info(f"Eliminando stack: {stack_name} en {region}")
                cf_client.delete_stack(StackName=stack_name)
                
                # Esperar a que se complete la eliminación
                try:
                    waiter = cf_client.get_waiter('stack_delete_complete')
                    waiter.wait(StackName=stack_name, WaiterConfig={'Delay': 10, 'MaxAttempts': 60})
                    logger.info(f"Stack {stack_name} eliminado exitosamente en {region}")
                    
                    cleanup_report.add_success(account_name, "CloudFormation Stack", stack_name, region)
                    deleted_count += 1
                except Exception as wait_error:
                    # Si el waiter falla, verificar el estado del stack
                    try:
                        stack_status = cf_client.describe_stacks(StackName=stack_name)['Stacks'][0]['StackStatus']
                        if stack_status == 'DELETE_COMPLETE':
                            logger.info(f"Stack {stack_name} eliminado exitosamente en {region}")
                            cleanup_report.add_success(account_name, "CloudFormation Stack", stack_name, region)
                            deleted_count += 1
                        elif stack_status == 'DELETE_FAILED':
                            error_msg = f"Stack {stack_name} falló al eliminarse (DELETE_FAILED). Puede requerir eliminación manual."
                            logger.warning(error_msg)
                            cleanup_report.add_error(account_name, "CloudFormation Stack", stack_name, f"Estado: {stack_status} - Requiere eliminación manual", region)
                        else:
                            error_msg = f"Stack {stack_name} en estado inesperado: {stack_status}"
                            logger.warning(error_msg)
                            cleanup_report.add_error(account_name, "CloudFormation Stack", stack_name, f"Estado: {stack_status}", region)
                    except Exception as status_error:
                        error_msg = f"Error al verificar estado del stack {stack_name}: {status_error}"
                        logger.warning(error_msg)
                        cleanup_report.add_error(account_name, "CloudFormation Stack", stack_name, status_error, region)
                
            except ClientError as e:
                error_msg = f"Error al eliminar stack {stack_name} en {region}: {e}"
                logger.error(error_msg)
                cleanup_report.add_error(account_name, "CloudFormation Stack", stack_name, e, region)
        
        cleanup_report.add_resource_deleted(account_name, "CloudFormation Stacks", deleted_count)

def list_cloudwatch_log_groups(session, account_name, delete_mode=False):
    """Listar o eliminar grupos de logs de CloudWatch relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando grupos de logs SRA en {account_name}...")
    else:
        logger.info(f"Revisando grupos de logs SRA en {account_name}...")
    
    all_sra_log_groups = []
    
    # Procesar cada región
    for region in SRA_REGIONS:
        try:
            logs_client = session.client('logs', region_name=region)
            
            # Listar grupos de logs
            paginator = logs_client.get_paginator('describe_log_groups')
            region_log_groups = []
            
            for page in paginator.paginate():
                for log_group in page['logGroups']:
                    if 'sra' in log_group['logGroupName'].lower():
                        region_log_groups.append({'name': log_group['logGroupName'], 'region': region})
            
            if region_log_groups:
                logger.info(f"Encontrados {len(region_log_groups)} grupos de logs SRA en {account_name} ({region})")
                all_sra_log_groups.extend(region_log_groups)
                cleanup_report.add_resource_found(account_name, "CloudWatch Log Groups", len(region_log_groups), region)
            
        except ClientError as e:
            error_msg = f"Error al listar grupos de logs en {account_name} ({region}): {e}"
            logger.error(error_msg)
            cleanup_report.add_error(account_name, "CloudWatch Log Groups", "listado", e, region)
    
    if not all_sra_log_groups:
        logger.info(f"No se encontraron grupos de logs SRA en {account_name}")
        return
    
    logger.info(f"Total: {len(all_sra_log_groups)} grupos de logs SRA encontrados en {account_name}")
    
    if delete_mode:
        deleted_count = 0
        for log_group_info in all_sra_log_groups:
            try:
                log_group_name = log_group_info['name']
                region = log_group_info['region']
                logs_client = session.client('logs', region_name=region)
                
                logger.info(f"Eliminando grupo de logs: {log_group_name} en {region}")
                logs_client.delete_log_group(logGroupName=log_group_name)
                logger.info(f"Grupo de logs {log_group_name} eliminado exitosamente en {region}")
                
                cleanup_report.add_success(account_name, "CloudWatch Log Group", log_group_name, region)
                deleted_count += 1
                
            except ClientError as e:
                error_msg = f"Error al eliminar grupo de logs {log_group_name} en {region}: {e}"
                logger.error(error_msg)
                cleanup_report.add_error(account_name, "CloudWatch Log Group", log_group_name, e, region)
        
        cleanup_report.add_resource_deleted(account_name, "CloudWatch Log Groups", deleted_count)

def list_ssm_parameters(session, account_name, delete_mode=False):
    """Listar o eliminar parámetros SSM relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando parámetros SSM SRA en {account_name}...")
    else:
        logger.info(f"Revisando parámetros SSM SRA en {account_name}...")
    
    all_sra_parameters = []
    
    # Procesar cada región
    for region in SRA_REGIONS:
        try:
            ssm_client = session.client('ssm', region_name=region)
            
            # Listar parámetros que contengan 'sra'
            paginator = ssm_client.get_paginator('describe_parameters')
            region_parameters = []
            
            for page in paginator.paginate():
                for param in page['Parameters']:
                    if 'sra' in param['Name'].lower():
                        region_parameters.append({'name': param['Name'], 'region': region})
            
            if region_parameters:
                logger.info(f"Encontrados {len(region_parameters)} parámetros SSM SRA en {account_name} ({region})")
                all_sra_parameters.extend(region_parameters)
                cleanup_report.add_resource_found(account_name, "SSM Parameters", len(region_parameters), region)
            
        except ClientError as e:
            error_msg = f"Error al listar parámetros SSM en {account_name} ({region}): {e}"
            logger.error(error_msg)
            cleanup_report.add_error(account_name, "SSM Parameters", "listado", e, region)
    
    if not all_sra_parameters:
        logger.info(f"No se encontraron parámetros SSM SRA en {account_name}")
        return
    
    logger.info(f"Total: {len(all_sra_parameters)} parámetros SSM SRA encontrados en {account_name}")
    
    if delete_mode:
        # Agrupar parámetros por región para eliminación en lotes
        parameters_by_region = {}
        for param_info in all_sra_parameters:
            region = param_info['region']
            if region not in parameters_by_region:
                parameters_by_region[region] = []
            parameters_by_region[region].append(param_info['name'])
        
        # Eliminar parámetros por región en lotes de 10
        deleted_count = 0
        for region, parameters in parameters_by_region.items():
            ssm_client = session.client('ssm', region_name=region)
            for i in range(0, len(parameters), 10):
                batch = parameters[i:i+10]
                try:
                    logger.info(f"Eliminando lote de parámetros en {region}: {batch}")
                    ssm_client.delete_parameters(Names=batch)
                    logger.info(f"Lote de parámetros eliminado exitosamente en {region}")
                    
                    for param_name in batch:
                        cleanup_report.add_success(account_name, "SSM Parameter", param_name, region)
                        deleted_count += 1
                    
                except ClientError as e:
                    error_msg = f"Error al eliminar lote de parámetros en {region}: {e}"
                    logger.error(error_msg)
                    for param_name in batch:
                        cleanup_report.add_error(account_name, "SSM Parameter", param_name, e, region)
        
        cleanup_report.add_resource_deleted(account_name, "SSM Parameters", deleted_count)

def list_iam_roles(session, account_name, delete_mode=False):
    """Listar o eliminar roles IAM relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando roles IAM SRA en {account_name}...")
    else:
        logger.info(f"Revisando roles IAM SRA en {account_name}...")
    
    iam_client = session.client('iam')
    
    try:
        # Listar roles que contengan 'sra'
        paginator = iam_client.get_paginator('list_roles')
        sra_roles = []
        
        for page in paginator.paginate():
            for role in page['Roles']:
                if 'sra' in role['RoleName'].lower():
                    sra_roles.append(role['RoleName'])
        
        if not sra_roles:
            logger.info(f"No se encontraron roles IAM SRA en {account_name}")
            return
        
        logger.info(f"Encontrados {len(sra_roles)} roles IAM SRA en {account_name}")
        cleanup_report.add_resource_found(account_name, "IAM Roles", len(sra_roles))
        
        if delete_mode:
            deleted_count = 0
            for role_name in sra_roles:
                try:
                    # Eliminar políticas adjuntas
                    attached_policies = iam_client.list_attached_role_policies(RoleName=role_name)
                    for policy in attached_policies['AttachedPolicies']:
                        logger.info(f"Desvinculando política {policy['PolicyName']} del rol {role_name}")
                        iam_client.detach_role_policy(RoleName=role_name, PolicyArn=policy['PolicyArn'])
                    
                    # Eliminar políticas inline
                    inline_policies = iam_client.list_role_policies(RoleName=role_name)
                    for policy_name in inline_policies['PolicyNames']:
                        logger.info(f"Eliminando política inline {policy_name} del rol {role_name}")
                        iam_client.delete_role_policy(RoleName=role_name, PolicyName=policy_name)
                    
                    # Eliminar el rol
                    logger.info(f"Eliminando rol: {role_name}")
                    iam_client.delete_role(RoleName=role_name)
                    logger.info(f"Rol {role_name} eliminado exitosamente")
                    
                    cleanup_report.add_success(account_name, "IAM Role", role_name)
                    deleted_count += 1
                    
                except ClientError as e:
                    error_msg = f"Error al eliminar rol {role_name}: {e}"
                    logger.error(error_msg)
                    cleanup_report.add_error(account_name, "IAM Role", role_name, e)
            
            cleanup_report.add_resource_deleted(account_name, "IAM Roles", deleted_count)
                
    except ClientError as e:
        error_msg = f"Error al listar roles IAM en {account_name}: {e}"
        logger.error(error_msg)
        cleanup_report.add_error(account_name, "IAM Roles", "listado", e)

def list_lambda_functions(session, account_name, delete_mode=False):
    """Listar o eliminar funciones Lambda relacionadas con SRA"""
    if delete_mode:
        logger.info(f"Eliminando funciones Lambda SRA en {account_name}...")
    else:
        logger.info(f"Revisando funciones Lambda SRA en {account_name}...")
    
    all_sra_functions = []
    
    # Procesar cada región
    for region in SRA_REGIONS:
        try:
            lambda_client = session.client('lambda', region_name=region)
            
            # Listar funciones que contengan 'sra'
            paginator = lambda_client.get_paginator('list_functions')
            region_functions = []
            
            for page in paginator.paginate():
                for function in page['Functions']:
                    if 'sra' in function['FunctionName'].lower():
                        region_functions.append({'name': function['FunctionName'], 'region': region})
            
            if region_functions:
                logger.info(f"Encontradas {len(region_functions)} funciones Lambda SRA en {account_name} ({region})")
                all_sra_functions.extend(region_functions)
                cleanup_report.add_resource_found(account_name, "Lambda Functions", len(region_functions), region)
            
        except ClientError as e:
            error_msg = f"Error al listar funciones Lambda en {account_name} ({region}): {e}"
            logger.error(error_msg)
            cleanup_report.add_error(account_name, "Lambda Functions", "listado", e, region)
    
    if not all_sra_functions:
        logger.info(f"No se encontraron funciones Lambda SRA en {account_name}")
        return
    
    logger.info(f"Total: {len(all_sra_functions)} funciones Lambda SRA encontradas en {account_name}")
    
    if delete_mode:
        deleted_count = 0
        for function_info in all_sra_functions:
            try:
                function_name = function_info['name']
                region = function_info['region']
                lambda_client = session.client('lambda', region_name=region)
                
                logger.info(f"Eliminando función Lambda: {function_name} en {region}")
                lambda_client.delete_function(FunctionName=function_name)
                logger.info(f"Función Lambda {function_name} eliminada exitosamente en {region}")
                
                cleanup_report.add_success(account_name, "Lambda Function", function_name, region)
                deleted_count += 1
                
            except ClientError as e:
                error_msg = f"Error al eliminar función Lambda {function_name} en {region}: {e}"
                logger.error(error_msg)
                cleanup_report.add_error(account_name, "Lambda Function", function_name, e, region)
        
        cleanup_report.add_resource_deleted(account_name, "Lambda Functions", deleted_count)

def list_s3_buckets(session, account_name, delete_mode=False):
    """Listar o eliminar buckets S3 relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando buckets S3 SRA en {account_name}...")
    else:
        logger.info(f"Revisando buckets S3 SRA en {account_name}...")
    
    s3_client = session.client('s3')
    
    try:
        # Listar buckets que contengan 'sra'
        response = s3_client.list_buckets()
        sra_buckets = []
        
        for bucket in response['Buckets']:
            if 'sra' in bucket['Name'].lower():
                sra_buckets.append(bucket['Name'])
        
        if not sra_buckets:
            logger.info(f"No se encontraron buckets S3 SRA en {account_name}")
            return
        
        logger.info(f"Encontrados {len(sra_buckets)} buckets S3 SRA en {account_name}")
        cleanup_report.add_resource_found(account_name, "S3 Buckets", len(sra_buckets))
        
        if delete_mode:
            deleted_count = 0
            for bucket_name in sra_buckets:
                try:
                    # Eliminar todos los objetos del bucket
                    logger.info(f"Eliminando objetos del bucket: {bucket_name}")
                    
                    # Listar y eliminar versiones de objetos
                    paginator = s3_client.get_paginator('list_object_versions')
                    for page in paginator.paginate(Bucket=bucket_name):
                        if 'Versions' in page:
                            for obj in page['Versions']:
                                s3_client.delete_object(
                                    Bucket=bucket_name,
                                    Key=obj['Key'],
                                    VersionId=obj['VersionId']
                                )
                        
                        if 'DeleteMarkers' in page:
                            for marker in page['DeleteMarkers']:
                                s3_client.delete_object(
                                    Bucket=bucket_name,
                                    Key=marker['Key'],
                                    VersionId=marker['VersionId']
                                )
                    
                    # Eliminar el bucket
                    logger.info(f"Eliminando bucket: {bucket_name}")
                    s3_client.delete_bucket(Bucket=bucket_name)
                    logger.info(f"Bucket {bucket_name} eliminado exitosamente")
                    
                    cleanup_report.add_success(account_name, "S3 Bucket", bucket_name)
                    deleted_count += 1
                    
                except ClientError as e:
                    error_msg = f"Error al eliminar bucket {bucket_name}: {e}"
                    logger.error(error_msg)
                    cleanup_report.add_error(account_name, "S3 Bucket", bucket_name, e)
            
            cleanup_report.add_resource_deleted(account_name, "S3 Buckets", deleted_count)
                
    except ClientError as e:
        error_msg = f"Error al listar buckets S3 en {account_name}: {e}"
        logger.error(error_msg)
        cleanup_report.add_error(account_name, "S3 Buckets", "listado", e)

def list_cloudformation_stacksets(session, account_name, delete_mode=False):
    """Listar o eliminar StackSets de CloudFormation relacionados con SRA"""
    if delete_mode:
        logger.info(f"Eliminando StackSets SRA en {account_name}...")
    else:
        logger.info(f"Revisando StackSets SRA en {account_name}...")
    
    cf_client = session.client('cloudformation')
    
    try:
        # Listar StackSets que contengan 'sra' en el nombre y NO estén eliminados
        paginator = cf_client.get_paginator('list_stack_sets')
        sra_stacksets = []
        
        for page in paginator.paginate():
            for stackset in page['Summaries']:
                # Solo incluir StackSets que contengan 'sra' y NO estén en estado DELETED
                if ('sra' in stackset['StackSetName'].lower() and 
                    stackset['Status'] != 'DELETED'):
                    sra_stacksets.append(stackset['StackSetName'])
        
        if not sra_stacksets:
            logger.info(f"No se encontraron StackSets SRA en {account_name}")
            return
        
        logger.info(f"Encontrados {len(sra_stacksets)} StackSets SRA en {account_name}: {sra_stacksets}")
        cleanup_report.add_resource_found(account_name, "CloudFormation StackSets", len(sra_stacksets))
        
        if delete_mode:
            deleted_count = 0
            for stackset_name in sra_stacksets:
                try:
                    logger.info(f"Eliminando StackSet: {stackset_name}")
                    
                    # Primero eliminar las instancias del StackSet en todas las cuentas
                    logger.info(f"Eliminando instancias del StackSet {stackset_name}...")
                    
                    # Listar todas las instancias del StackSet
                    instances_paginator = cf_client.get_paginator('list_stack_instances')
                    instances_to_delete = []
                    
                    for page in instances_paginator.paginate(StackSetName=stackset_name):
                        for instance in page['Summaries']:
                            instances_to_delete.append({
                                'Account': instance['Account'],
                                'Region': instance['Region']
                            })
                    
                    if instances_to_delete:
                        logger.info(f"Eliminando {len(instances_to_delete)} instancias del StackSet {stackset_name}")
                        
                        # Eliminar instancias en lotes (AWS permite hasta 10 por operación)
                        for i in range(0, len(instances_to_delete), 10):
                            batch = instances_to_delete[i:i+10]
                            accounts = [instance['Account'] for instance in batch]
                            regions = [instance['Region'] for instance in batch]
                            
                            try:
                                cf_client.delete_stack_instances(
                                    StackSetName=stackset_name,
                                    Accounts=accounts,
                                    Regions=regions,
                                    RetainStacks=False
                                )
                                logger.info(f"Eliminadas {len(batch)} instancias del StackSet {stackset_name}")
                                
                                # Esperar a que se complete la eliminación de instancias
                                time.sleep(10)
                                
                            except ClientError as e:
                                error_msg = f"Error al eliminar instancias del StackSet {stackset_name}: {e}"
                                logger.error(error_msg)
                                cleanup_report.add_error(account_name, "CloudFormation StackSet Instances", stackset_name, e)
                    
                    # Finalmente eliminar el StackSet
                    logger.info(f"Eliminando StackSet: {stackset_name}")
                    cf_client.delete_stack_set(StackSetName=stackset_name)
                    logger.info(f"StackSet {stackset_name} eliminado exitosamente")
                    
                    cleanup_report.add_success(account_name, "CloudFormation StackSet", stackset_name)
                    deleted_count += 1
                    
                except ClientError as e:
                    error_msg = f"Error al eliminar StackSet {stackset_name}: {e}"
                    logger.error(error_msg)
                    cleanup_report.add_error(account_name, "CloudFormation StackSet", stackset_name, e)
            
            cleanup_report.add_resource_deleted(account_name, "CloudFormation StackSets", deleted_count)
                
    except ClientError as e:
        error_msg = f"Error al listar StackSets en {account_name}: {e}"
        logger.error(error_msg)
        cleanup_report.add_error(account_name, "CloudFormation StackSets", "listado", e)

def scan_account(account_key, account_config, delete_mode=False):
    """Escanear o limpiar todos los recursos SRA de una cuenta específica"""
    mode_text = "ELIMINACIÓN" if delete_mode else "REVISIÓN"
    action_text = "eliminación" if delete_mode else "revisión"
    
    logger.info(f"\n{'='*60}")
    logger.info(f"INICIANDO {mode_text} DE {account_config['name'].upper()}")
    logger.info(f"{'='*60}")
    
    session = get_session(account_config['profile'])
    if not session:
        logger.error(f"No se pudo conectar a {account_config['name']}")
        cleanup_report.add_error(account_config['name'], "Conexión", "sesión", "No se pudo establecer conexión")
        return False
    
    try:
        # Procesar recursos en orden específico para evitar dependencias
        list_cloudformation_stacks(session, account_config['name'], delete_mode)
        list_lambda_functions(session, account_config['name'], delete_mode)
        list_iam_roles(session, account_config['name'], delete_mode)
        list_ssm_parameters(session, account_config['name'], delete_mode)
        list_cloudwatch_log_groups(session, account_config['name'], delete_mode)
        list_s3_buckets(session, account_config['name'], delete_mode)
        
        # Solo procesar StackSets en la cuenta master (donde se crean)
        if account_key == 'master':
            list_cloudformation_stacksets(session, account_config['name'], delete_mode)
        
        logger.info(f"{action_text.capitalize()} completada para {account_config['name']}")
        return True
        
    except Exception as e:
        error_msg = f"Error durante la {action_text} de {account_config['name']}: {e}"
        logger.error(error_msg)
        cleanup_report.add_error(account_config['name'], "Proceso General", "scan_account", e)
        return False

def main():
    """Función principal"""
    args = parse_arguments()
    
    if args.delete:
        logger.info("🗑️ MODO ELIMINACIÓN ACTIVADO")
        logger.info("Este script eliminará todos los recursos relacionados con SRA")
        logger.info("de las cuentas Master, Audit y Log Archive")
        
        # Confirmación adicional para modo eliminación
        logger.info("⚠️ CONFIRMACIÓN: Procediendo con eliminación de recursos SRA")
        # response = input("\n⚠️ ¿Estás seguro de que quieres ELIMINAR los recursos? (yes/no): ")
        # if response.lower() != 'yes':
        #     logger.info("Operación cancelada por el usuario")
        #     return
    else:
        logger.info("🔍 MODO REVISIÓN ACTIVADO")
        logger.info("Este script revisará todos los recursos relacionados con SRA")
        logger.info("de las cuentas Master, Audit y Log Archive")
        logger.info("No se eliminará ningún recurso")
    
    success_count = 0
    total_accounts = len(ACCOUNTS)
    
    # Procesar cada cuenta
    for account_key, account_config in ACCOUNTS.items():
        if scan_account(account_key, account_config, args.delete):
            success_count += 1
    
    # Imprimir reporte detallado
    cleanup_report.print_summary(args.delete)
    
    # Resumen final
    action_text = "ELIMINACIÓN" if args.delete else "REVISIÓN"
    logger.info(f"\n{'='*60}")
    logger.info(f"RESUMEN DE {action_text}")
    logger.info(f"{'='*60}")
    logger.info(f"Cuentas procesadas: {total_accounts}")
    logger.info(f"Cuentas exitosas: {success_count}")
    logger.info(f"Cuentas con errores: {total_accounts - success_count}")
    
    if success_count == total_accounts:
        if args.delete:
            logger.info("✅ ELIMINACIÓN COMPLETADA EXITOSAMENTE")
        else:
            logger.info("✅ REVISIÓN COMPLETADA EXITOSAMENTE")
            logger.info("Para eliminar los recursos encontrados, ejecuta:")
            logger.info("python cleanup-sra.py --delete")
    else:
        logger.warning(f"⚠️ {action_text} COMPLETADA CON ERRORES")
        logger.info("Revisa el reporte detallado anterior para más detalles")

if __name__ == "__main__":
    main() 