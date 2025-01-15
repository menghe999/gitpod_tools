#!/bin/bash

# 配置项
COUNTRY="CN"                  # 国家代码
STATE="Zhejiang"              # 省/州
LOCALITY="Hangzhou"           # 城市
ORGANIZATION="DTDream"        # 组织名称
ORGANIZATIONAL_UNIT="Security" # 部门名称
COMMON_NAME="zelda.com"       # 通用名称（域名）
VALIDITY_DAYS=9999            # 有效期（天数）
KEYSTORE_NAME="keystore"      # 密钥库文件名
TRUSTSTORE_NAME="truststore"  # 信任库文件名
KEY_ALIAS="localhost"         # 密钥别名
CA_ALIAS="CARoot"             # CA证书别名
KEY_ALG="RSA"                 # 密钥算法
KEY_SIZE=2048                 # 密钥长度
CA_KEY="test_ca_key"          # CA私钥文件名
CA_CERT="test_ca_cert"        # CA证书文件名
PASSWORD="changeit"           # 密钥库和信任库的密码

# 生成自签名CA证书
generate_ca_cert() {
    echo "Generating self-signed CA certificate..."
    openssl req -new -x509 -keyout "$CA_KEY" -out "$CA_CERT" -days "$VALIDITY_DAYS" \
        -subj "/C=$COUNTRY/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=$COMMON_NAME" \
        -passout pass:"$PASSWORD"
    echo "CA certificate generated: $CA_CERT"
}

# 创建密钥库并生成密钥对
generate_keystore() {
    echo "Generating keystore and key pair..."
    keytool -keystore "$KEYSTORE_NAME" -alias "$KEY_ALIAS" -validity "$VALIDITY_DAYS" \
        -genkey -keyalg "$KEY_ALG" -keysize "$KEY_SIZE" \
        -dname "CN=$COMMON_NAME, OU=$ORGANIZATIONAL_UNIT, O=$ORGANIZATION, L=$LOCALITY, ST=$STATE, C=$COUNTRY" \
        -storepass "$PASSWORD" -keypass "$PASSWORD"
    echo "Keystore generated: $KEYSTORE_NAME"
}

# 将CA证书导入信任库
import_ca_to_truststore() {
    echo "Importing CA certificate into truststore..."
    keytool -keystore "$TRUSTSTORE_NAME" -alias "$CA_ALIAS" -import -file "$CA_CERT" \
        -storepass "$PASSWORD" -noprompt
    echo "CA certificate imported into truststore: $TRUSTSTORE_NAME"
}

# 生成证书签名请求（CSR）
generate_csr() {
    echo "Generating certificate signing request (CSR)..."
    keytool -certreq -alias "$KEY_ALIAS" -keystore "$KEYSTORE_NAME" -file cert.csr \
        -storepass "$PASSWORD" -keypass "$PASSWORD"
    echo "CSR generated: cert.csr"
}

# 使用CA证书对CSR进行签名
sign_csr() {
    echo "Signing CSR with CA certificate..."
    openssl x509 -req -CA "$CA_CERT" -CAkey "$CA_KEY" -in cert.csr -out cert_signed.crt \
        -days "$VALIDITY_DAYS" -CAcreateserial -passin pass:"$PASSWORD"
    echo "CSR signed: cert_signed.crt"
}

# 将CA证书导入密钥库
import_ca_to_keystore() {
    echo "Importing CA certificate into keystore..."
    keytool -keystore "$KEYSTORE_NAME" -alias "$CA_ALIAS" -import -file "$CA_CERT" \
        -storepass "$PASSWORD" -noprompt
    echo "CA certificate imported into keystore."
}

# 将签名后的证书导入密钥库
import_signed_cert_to_keystore() {
    echo "Importing signed certificate into keystore..."
    keytool -keystore "$KEYSTORE_NAME" -alias "$KEY_ALIAS" -import -file cert_signed.crt \
        -storepass "$PASSWORD" -keypass "$PASSWORD" -noprompt
    echo "Signed certificate imported into keystore."
}

# 清理临时文件
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f cert.csr cert_signed.crt test_ca_key test_ca_cert
    echo "Cleanup complete."
}

# 主函数
main() {
    generate_ca_cert
    generate_keystore
    import_ca_to_truststore
    generate_csr
    sign_csr
    import_ca_to_keystore
    import_signed_cert_to_keystore
    cleanup
    echo "All operations completed successfully!"
}

# 执行主函数
main
