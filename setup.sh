#!/bin/sh

## Paramètres (à précéder de '--') :
## - skip-llvm : ne pas compiler LLVM. Utiliser pour reprendre une compilation échouée ou pour utiliser la version de votre système. Dans ce dernier cas, modifiez ${LLVM_INSTALL_DIR} et ${LLVM_VERSION} avec les valeurs de votre système.
## - no-clean : ne pas supprimer le répertoire temporaire. Permet de gagner du temps en cas de reprise, mais peut créer des conflits.
## - no-fetch : ne pas récupérer les sources depuis le web. Echouera lamentablement sans --no-clean.
## - no-gcc-47 : à activer si vous avez gcc < 4.7. La version 4.7 introduit une fonctionnalité qui casse la compilation. Ce flag sert à désactiver la correction.
## - keep-llvm : ne pas supprimer le dossier de LLVM. Rubinius étant lié statiquement à LLVM, garder le dossier est inutile après installation.

die() {
	echo $1
	exit
}

# Laisser une chaîne de caractère vide si les dossiers d'installation ne nécessitent pas les droits super-utilisateur
ROOT="sudo"

LLVM_INSTALL_DIR="/tmp/llvm"
# N'oubliez pas modifier cette variable dans set_rbx.sh et install_norminette.sh aussi!
RBX_INSTALL_DIR="/opt/42norminette_rubinius"

NORMINETTE_PREFIX="/opt"

# Le dossier où seront installés les liens. Il est obligatoire que ce chemin soit avant ruby dans votre PATH et recommandé qu'il soit différent afin de ne pas créer de conflits.
LINK_DIR="/usr/local/bin"

# Number of threads
NBTHREADS=`cat /proc/cpuinfo | grep processor | wc -l`

## Vous pouvez modifier les versions si vous voulez. Mais ces versions sont connues fonctionnelles, il est fort probable que d'autres combos ne fonctionneront pas.
## Si vraiment vous voulez tester d'autres versions, lisez attentivement tous les commentaires du fichier.

# Les dernières versions (LLVM 3.5+) sont incompatibles. Rubinius requiert LLVM 3.5 max et les versions 2.2.x ne compilent pas sur LLVM 3.5.
LLVM_VERSION="3.4.2"
# Les dumps utilisent 2.2.6. Je ne garantis aucun résultat avec d'autres versions
RBX_VERSION="2.2.6"
# Autodétection de la version de bundler. Si ça ne marche pas pour une raison quelconque, vous devrez la spécifier à la main
BUNDLER_VERSION=`bundler -v | sed -E 's/Bundler version (.*)/\1/'`

if [ -z ${BUNDLER_VERSION} ]
then
	die "Echec de l'autodétection de la version de bundler. Vous devrez spécifier la variable BUNDLER_VERSION à la main"
fi

# Options du script. Modifier avec les paramètres (voir ci dessus)
SKIP_LLVM="no"
CLEAN="yes"
FETCH="yes"
HAVE_GCC_47="yes"
KEEP_LLVM="no"

until [ -z "$1" ]
do
	if [ $1 = "--skip-llvm" ]
	then
		SKIP_LLVM="yes"
	fi
	if [ $1 = "--no-clean" ]
	then
		CLEAN="no"
	fi
	if [ $1 = "--no-fetch" ]
	then
		FETCH="no"
	fi
	if [ $1 = "--no-gcc47-fix" ]
	then
		HAVE_GCC_47="no"
	fi
	if [ $1 = "--keep-llvm" ]
	then
		KEEP_LLVM="yes"
	fi
	shift
done

# C'est parti!

if [ ${CLEAN} = "yes" ]
then
	rm -fr tmp
fi

mkdir -p tmp
cd tmp

# Même si llvm peut être désactivé, la compilation échoue lamentablement sans.
if [ ${SKIP_LLVM} = "no" ]
then
	if [ ${FETCH} = "yes" ]
	then
		wget http://releases.llvm.org/${LLVM_VERSION}/llvm-${LLVM_VERSION}.src.tar.gz || die "Echec du téléchargement de LLVM Vérifiez votre connexion internet."
	fi
	tar -xf llvm-${LLVM_VERSION}.src.tar.gz
	cd llvm-${LLVM_VERSION}.src
	./configure --disable-assertions --disable-shared --prefix=${LLVM_INSTALL_DIR} --disable-docs --enable-libffi --enable-optimized || die "Echec de la configuration de LLVM"
	make -j${NBTHREADS} || die "Echec de la compilation de LLVM"
	${ROOT} make install || die "Echec de l'installation de LLVM. Vérifiez vos droits."
	cd ..
fi

# Au cas ou GCC ne soit pas le compilateur par défaut. Rubinius est incompatible avec les autres.
export CC=gcc
export CXX="g++ -I/usr/include/x86_64-linux-gnu/ruby-2.1.0 -I/usr/include/ruby-2.1.0"

if [ ${FETCH} = "yes" ]
then
	wget http://releases.rubini.us/rubinius-${RBX_VERSION}.tar.bz2 || die "Echec du téléchargement de Rubinius. Vérifiez votre connexion internet."
fi
tar -xf rubinius-${RBX_VERSION}.tar.bz2
cd rubinius-${RBX_VERSION}
cp ../../rubinius/Gemfile .
bundle install --path=. || die "Echec de l'installation des dépendances de rubinius. Avez vous oublié d'installer bundler?"

# Hack pour forcer C++11, Rubinius n'est pas foutu de l'activer lui même alors qu'il en a besoin.
export CXX="g++ -std=c++11"

./configure --llvm-path="${LLVM_INSTALL_DIR}" --prefix="${RBX_INSTALL_DIR}" --llvm-config="${LLVM_INSTALL_DIR}/bin/llvm-config" || die "Echec de la configuration de Rubinius"
# Correction stupide pour corriger une correction stupide, affectant GCC entre les versions 5.0 et 5.2 comprises. Comme cette correction n'a aucun effet négatif, elle n'est pas désactivable.
sed -i "s/#if __clang__ || (__GNUC__ >= 4 \&\& __GNUC_MINOR__ >= 3)/\#if __clang__ || (__GNUC__ >= 4 \&\& __GNUC_MINOR__ >= 3) || __GNUC__ >= 5/" vm/object_utils.hpp || die "Fix failed"
# GCC 5.2 ne semble pas être capable de comparer deux std::ostream, on compare donc les buffers sous jacents. Cela ne change rien, à part augmenter la compatibilité, donc il n'est pas nécessaire de le faire optionnel non plus.
sed -i "s/      if(jit_log != std::cerr) {/      if(jit_log.rdbuf() != std::cerr.rdbuf()) {/" vm/environment.cpp || die "Fix failed"
if [ ${HAVE_GCC_47} = "yes" ]
then
	bundle exec rake
	sed -i "s/rb_warning0(\"\`\"op\"' after local variable is interpreted as binary operator\")/rb_warning0(\"\`\" op \"' after local variable is interpreted as binary operator\")/" staging/runtime/gems/rubinius-melbourne-2.1.0.0/ext/rubinius/melbourne/grammar.cpp
	sed -i 's/rb_warning0("even though it seems like "syn""))/rb_warning0("even though it seems like " syn ""))/' staging/runtime/gems/rubinius-melbourne-2.1.0.0/ext/rubinius/melbourne/grammar.cpp
fi
bundle exec rake || die "Echec de la compilation de Rubinius"
${ROOT} bundle exec rake install || die "Echec de l'installation de Rubinius"
${ROOT} ${RBX_INSTALL_DIR}/bin/gem install bundler -v ${BUNDLER_VERSION} || echo "Failed to install bundler"

if [ ${KEEP_LLVM} = "no" ]
then
	${ROOT} rm -fr ${LLVM_INSTALL_DIR}
fi

cd ../..
rm -fr tmp

##############################################################################################################################################################

# Options du script. Modifier avec les paramètres
## - no-link : ne pas créer de lien pour exécuter la norminette
## - no-clean : ne pas supprimer l'ancienne installation de la norminette

LINK="yes"
CLEAN="yes"

until [ -z "$1" ]
do
	if [ $1 = "--no-link" ]
	then
		LINK="no"
	fi
	if [ $1 = "--no-clean" ]
	then
		CLEAN="no"
	fi
	shift
done


# C'est parti!

if [ ${CLEAN} = "yes" ]
then
	${ROOT} rm -fr ${NORMINETTE_PREFIX}/42norminette
	if [ ${LINK} = "yes" ]
	then
		${ROOT} rm -f ${LINK_DIR}/42norminette
	fi
fi

${ROOT} mkdir -p ${NORMINETTE_PREFIX}
cd ${NORMINETTE_PREFIX}
${ROOT} tar xf ${OLDPWD}/norminette/norminette.tar.bz2
cd 42norminette

${ROOT} ${RBX_INSTALL_DIR}/gems/bin/bundle install --path=. || die "Echec de l'installation des gemmes"

${ROOT} sed -i "s@/usr/bin/rbx@${RBX_INSTALL_DIR}/bin/rbx@" norminette.rb || die "Echec de la compilation de norminette.rb. Vérifiez votre installation de rubinius."

# Corriger la signature des fichiers compilés pour notre installation de Rubinius
${ROOT} ${RBX_INSTALL_DIR}/bin/rbx compile -o norminette.rbc norminette.rb
OLD_SIG=`head -n 2 compiled/rules.rbc | tail -n 1`
NEW_SIG=`head -n 2 norminette.rbc | tail -n 1`
${ROOT} sed -i "s/${OLD_SIG}/${NEW_SIG}/" compiled/rules.rbc
${ROOT} sed -i "s/${OLD_SIG}/${NEW_SIG}/" compiled/*/*.rbc
${ROOT} rm norminette.rbc

${ROOT} sh -c 'echo "gem \"digest/hmac\"" >> Gemfile'
${ROOT} sh -c 'echo "BUNDLE_FROZEN: \"1\"" >> .bundle/config'

if [ ${LINK} = "yes" ]
then
	${ROOT} ln -s ${NORMINETTE_PREFIX}/42norminette/norminette.rb ${LINK_DIR}/42norminette
fi
