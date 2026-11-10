import tseslint from '@typescript-eslint/parser'
import tsdoc from 'eslint-plugin-tsdoc'
import jsdoc from 'eslint-plugin-jsdoc'

export default [
  {
    ignores: ['node_modules/', 'lib/', 'dist/', 'coverage/', 'docs/'],
  },
  {
    files: ['packages/*/src/**/*.ts'],
    languageOptions: {
      parser: tseslint,
      ecmaVersion: 2024,
      sourceType: 'module',
    },
    plugins: {
      tsdoc,
      jsdoc,
    },
    rules: {
      'tsdoc/syntax': 'error',
      'jsdoc/require-jsdoc': [
        'error',
        {
          publicOnly: true,
          contexts: [
            'ExportNamedDeclaration > FunctionDeclaration',
            'ExportNamedDeclaration > ClassDeclaration',
            'ExportNamedDeclaration > TSInterfaceDeclaration',
            'ExportNamedDeclaration > TSTypeAliasDeclaration',
            'ExportNamedDeclaration > TSEnumDeclaration',
            'ExportNamedDeclaration > TSModuleDeclaration',
            'ExportNamedDeclaration > VariableDeclaration > VariableDeclarator[id.typeAnnotation]',
            'ExportDefaultDeclaration > FunctionDeclaration',
            'ExportDefaultDeclaration > ClassDeclaration',
            'ExportNamedDeclaration > TSInterfaceDeclaration > TSInterfaceBody > TSPropertySignature',
            'ExportNamedDeclaration > ClassDeclaration > ClassBody > MethodDefinition:not([key.name="constructor"])',
          ],
          exemptEmptyConstructors: true,
          exemptEmptyFunctions: false,
        },
      ],
      'jsdoc/require-param': [
        'error',
        {
          checkDestructured: false,
        },
      ],
      'jsdoc/require-returns': [
        'error',
        {
          publicOnly: true,
        },
      ],
      'jsdoc/require-description': 'error',
    },
  },
]
