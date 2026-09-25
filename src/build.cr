# Générateur du site vitrine d'Erik Pain, géomètre-expert.
#
# Lit les textes AsciiDoc de content/, les convertit en HTML avec asciicrystal,
# les injecte dans les gabarits de templates/ et écrit le site dans _site/.
#
#   shards build --release   # produit bin/build
#   bin/build                # génère _site/
#   bin/build --serve        # génère puis sert sur http://localhost:8765

require "asciicrystal"
require "uri"
require "file_utils"
require "http/server"

module Mendoro
  VERSION = "0.1.0"

  RACINE   = Path[__DIR__].parent
  CONTENU  = RACINE / "content"
  GABARITS = RACINE / "templates"
  SORTIE   = RACINE / "_site"
  # Le domaine personnalisé tient dans le réglage Pages du dépôt, pas ici :
  # publiant par un workflow Actions, GitHub ignore un fichier CNAME livré
  # dans l'artefact. En embarquer un donnerait l'illusion d'une source de
  # vérité qui n'en est pas une.
  STATIQUES = %w[css images]

  PORT_LOCAL = 8765

  # Un fichier .adoc découpé en trois : son titre (`= Titre`), ses attributs
  # d'en-tête (`:clef: valeur`) et le corps du document.
  struct Source
    getter titre : String
    getter attributs : Hash(String, String)
    getter corps : String
    # Identifiant de page, tiré du nom de fichier amputé de son préfixe
    # d'ordre : `02-bornage-amiable.adoc` donne `bornage-amiable`.
    getter slug : String
    # Nom de fichier entier, préfixe compris. Les actualités y lisent leur
    # date, que l'amputation ci-dessus effacerait.
    getter fichier : String

    def initialize(@titre, @attributs, @corps, @slug = "", @fichier = "")
    end

    # Adresse de la page correspondante dans le site généré.
    def page : String
      "#{slug}.html"
    end

    ATTRIBUT = /\A:([\w-]+):\s*(.*)\z/
    TITRE    = /\A=\s+(.+)\z/

    def self.lire(chemin : Path | String) : Source
      titre = ""
      attributs = {} of String => String
      corps = [] of String
      dans_entete = true

      File.each_line(chemin) do |ligne|
        if dans_entete
          # Les commentaires de ligne servent de notes aux rédacteurs.
          next if ligne.starts_with?("//")

          if m = TITRE.match(ligne)
            titre = m[1].strip
            next
          end

          if m = ATTRIBUT.match(ligne)
            attributs[m[1]] = m[2].strip
            next
          end

          # Une ligne vide en tête n'ouvre le corps que si l'en-tête a commencé.
          next if ligne.blank? && corps.empty?
          dans_entete = false
        end

        corps << ligne
      end

      fichier = File.basename(chemin.to_s, ".adoc")
      new(titre, attributs, corps.join('\n').strip, fichier.sub(/\A\d{4}-\d{2}-\d{2}-/, "").sub(/\A\d+-/, ""), fichier)
    end

    # Corps converti en fragment HTML. Sans « standalone => false »,
    # asciicrystal produit un document complet, feuille de style comprise.
    def html : String
      return "" if corps.empty?
      Asciicrystal.convert(corps, {"standalone" => "false"})
    end
  end

  # Remplace les marqueurs {{clef}} d'un gabarit. Un marqueur sans valeur
  # disparaît, ce qui évite de laisser des {{…}} dans la page livrée.
  def self.rendre(gabarit : String, valeurs : Hash(String, String)) : String
    gabarit.gsub(/\{\{([\w-]+)\}\}/) { valeurs[$~[1]]? || "" }
  end

  def self.gabarit(nom : String) : String
    File.read(GABARITS / "#{nom}.html")
  end

  # Un morceau de page, tiré de templates/fragments/. Tout le balisage vit
  # dans les gabarits : le générateur ne fait que choisir le fragment et lui
  # fournir des valeurs, échappées au besoin par l'appelant.
  #
  # Les commentaires d'un fragment sont des notes pour qui le maintient : ils
  # sont retirés avant rendu et ne partent pas dans les pages publiées.
  COMMENTAIRE = /^[ \t]*<!--.*?-->[ \t]*\n/m

  def self.fragment(nom : String, valeurs = {} of String => String) : String
    rendre(gabarit("fragments/#{nom}").gsub(COMMENTAIRE, "").chomp, valeurs)
  end

  def self.echapper(texte : String) : String
    texte.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
  end

  # Un lien s'ouvrant dans un nouvel onglet est signalé par un picto CSS,
  # décoratif et donc muet pour un lecteur d'écran. On y adjoint une mention
  # masquée à l'œil mais lue à voix haute.
  #
  # L'ajout est fait ici plutôt que dans les contenus : compter sur le
  # rédacteur pour l'écrire à chaque lien, c'est accepter qu'il l'oublie.
  LIEN_NOUVEL_ONGLET = /(<a\b[^>]*\btarget="_blank"[^>]*>)(.*?)(<\/a>)/m

  def self.signaler_liens_externes(html : String) : String
    mention = fragment("mention-nouvel-onglet")
    html.gsub(LIEN_NOUVEL_ONGLET) do |entier, m|
      # Ne pas doubler la mention si le rédacteur l'a déjà écrite lui-même.
      m[2].includes?("visually-hidden") ? entier : "#{m[1]}#{m[2]}#{mention}#{m[3]}"
    end
  end

  # ---------------------------------------------------------------- génération

  def self.generer
    site = Source.lire(CONTENU / "site.adoc").attributs
    prestations = charger_prestations
    actualites = charger_actualites

    FileUtils.rm_rf(SORTIE.to_s)
    Dir.mkdir_p(SORTIE.to_s)

    ecrire_accueil(site, prestations, actualites)
    prestations.each do |p|
      if p.attributs["liste"]? == "actualites"
        ecrire_index_actualites(site, prestations, p, actualites)
      else
        ecrire_prestation(site, prestations, p, actualites)
      end
    end
    actualites.each { |a| ecrire_actualite(site, prestations, a) }
    ecrire_contact(site, prestations)
    ecrire_mentions(site, prestations)
    copier_statiques

    puts "→ #{SORTIE} (#{prestations.size} prestations)"
  end

  # Actualités, de la plus récente à la plus ancienne. Le nom du fichier porte
  # la date — `2026-09-16-mise-en-ligne.adoc` — ce qui donne l'ordre sans
  # métadonnée à saisir, et une adresse de page lisible.
  def self.charger_actualites : Array(Source)
    dossier = CONTENU / "actualites"
    return [] of Source unless Dir.exists?(dossier)
    Dir.glob("#{dossier}/*.adoc").sort.reverse.map { |f| Source.lire(f) }
  end

  # Adresse de la page d'une actualité. Le préfixe écarte toute collision
  # avec une prestation qui porterait le même nom.
  def self.page_actu(a : Source) : String
    "actu-#{a.slug}.html"
  end

  # Une vidéo reconnue : sa plateforme, l'adresse à charger, et son
  # orientation — un « short » est tourné à la verticale et ne s'accommode
  # pas du cadre paysage.
  record Video, plateforme : String, url : String, vertical : Bool = false

  YOUTUBE_ID        = /\A[\w-]{11}\z/
  YOUTUBE_URL       = %r{(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/shorts/)([\w-]{11})}
  VIMEO_URL         = %r{vimeo\.com/(?:video/)?(\d+)}
  YOUTUBE_VERTICALE = %r{youtube\.com/shorts/}

  # L'attribut `:video:` accepte une adresse YouTube ou Vimeo complète, ou
  # l'identifiant YouTube seul. Reconnaître l'adresse épargne au rédacteur
  # d'aller y extraire un identifiant — y compris la forme « shorts », que
  # YouTube donne au partage depuis un téléphone et qui s'embarque comme
  # les autres.
  #
  # YouTube est chargé depuis `youtube-nocookie.com`, Vimeo avec `dnt=1` :
  # dans les deux cas, le mode le moins bavard que la plateforme propose.
  def self.reconnaitre_video(spec : String) : Video?
    if m = VIMEO_URL.match(spec)
      Video.new("Vimeo", "https://player.vimeo.com/video/#{m[1]}?dnt=1")
    elsif m = YOUTUBE_URL.match(spec)
      Video.new("YouTube", "https://www.youtube-nocookie.com/embed/#{m[1]}",
        vertical: YOUTUBE_VERTICALE.matches?(spec))
    elsif YOUTUBE_ID.matches?(spec)
      Video.new("YouTube", "https://www.youtube-nocookie.com/embed/#{spec}")
    end
  end

  # Le média d'une actualité : vidéo, photo, ou rien.
  def self.media_actu(a : Source) : String
    if spec = a.attributs["video"]?
      if video = reconnaitre_video(spec)
        fragment("video", {
          "format"     => video.vertical ? "vertical" : "paysage",
          "url"        => video.url,
          "titre"      => echapper(a.titre),
          "plateforme" => video.plateforme,
        })
      else
        fragment("media-absent", {"message" => "Adresse de la vidéo à renseigner."})
      end
    elsif photo = a.attributs["photo"]?
      # Une photo annoncée mais absente donnerait une image cassée : on
      # préfère n'afficher que la légende, et le signaler à la génération.
      if File.exists?(RACINE / photo)
        legende = a.attributs["legende"]?
        fragment("photo", {
          "src"     => photo,
          "alt"     => echapper(legende || a.titre),
          "legende" => legende ? fragment("legende", {"texte" => echapper(legende)}) : "",
        })
      else
        STDERR.puts "   ! photo absente : #{photo} (#{a.fichier})"
        fragment("media-absent", {"message" => "Photo à déposer : #{echapper(photo)}"})
      end
    else
      ""
    end
  end

  # `2026-09-16-mise-en-ligne` → `16 septembre 2026`, sans dépendance externe.
  MOIS = %w[janvier février mars avril mai juin juillet août septembre
    octobre novembre décembre]

  def self.date_lisible(slug : String) : String
    if m = /\A(\d{4})-(\d{2})-(\d{2})-/.match(slug)
      jour = m[3].to_i
      "#{jour == 1 ? "1er" : jour.to_s} #{MOIS[m[2].to_i - 1]} #{m[1]}"
    else
      ""
    end
  end

  # La carte de la dernière actualité, en accueil. Le résumé vient de
  # l'attribut `:resume:` : il est écrit pour être lu seul, ce qu'un extrait
  # tronqué du corps ne serait pas.
  def self.carte_actu(a : Source) : String
    media = media_actu(a)
    fragment("carte-actu", {
      "format" => media.empty? ? "texte" : "media",
      "media"  => media,
      "date"   => echapper(date_lisible(a.fichier)),
      "lien"   => page_actu(a),
      "titre"  => echapper(a.titre),
      "resume" => resume_actu(a),
    })
  end

  def self.resume_actu(a : Source) : String
    resume = a.attributs["resume"]?
    resume ? fragment("resume", {"texte" => echapper(resume)}) : ""
  end

  def self.charger_prestations : Array(Source)
    dossier = CONTENU / "prestations"
    Dir.glob("#{dossier}/*.adoc").sort.map { |f| Source.lire(f) }
  end

  # Le rappel des prestations, repris en pied de chaque page. La page
  # affichée porte `aria-current`, que les lecteurs d'écran annoncent et que
  # la feuille de style met en évidence.
  def self.menu_prestations(prestations, chemin_courant : String) : String
    prestations_du_menu(prestations).map do |p|
      lien_menu(p.page, p.titre, chemin_courant)
    end.join('\n')
  end

  def self.lien_menu(chemin : String, libelle : String, chemin_courant : String) : String
    nom = chemin == chemin_courant ? "lien-menu-courant" : "lien-menu"
    fragment(nom, {"lien" => chemin, "libelle" => echapper(libelle)})
  end

  # Les entrées du pied de page, suivies des mentions légales.
  def self.menu_pied(pages, chemin_courant : String) : String
    entrees = pages_du_pied(pages).map do |p|
      {p.page, p.titre}
    end
    entrees << {"mentions-legales.html", "Mentions légales"}

    entrees.map do |chemin, libelle|
      lien_menu(chemin, libelle, chemin_courant)
    end.join('\n')
  end

  # Valeurs communes à toutes les pages.
  def self.base(site, page : Source, chemin : String) : Hash(String, String)
    valeurs = {
      "chemin"         => chemin,
      "titre"          => page.titre,
      "intro"          => page.html,
      "page-title"     => page.attributs["page-title"]? || page.titre,
      "page-robots"    => page.attributs["page-robots"]? || "index, follow",
      "og-description" => page.attributs["og-description"]? ||
                          page.attributs["page-description"]? || "",
    } of String => String

    site.each { |clef, valeur| valeurs[clef] = valeur }
    page.attributs.each { |clef, valeur| valeurs[clef] = valeur }
    valeurs
  end

  def self.ecrire_accueil(site, prestations, actualites)
    page = Source.lire(CONTENU / "accueil.adoc")

    # La grille est titrée « Mes prestations » : les pages reléguées au pied
    # — carrière, actualités — n'y ont pas leur place.
    cartes = prestations_du_menu(prestations).map do |p|
      fragment("carte-prestation", {"lien" => p.page, "titre" => echapper(p.titre)})
    end

    # La dernière actualité passe devant les prestations. S'il n'y en a
    # aucune, le bloc disparaît plutôt que d'afficher un cadre vide.
    derniere = actualites.first?
    encart = derniere ? fragment("actu-une", {"carte" => carte_actu(derniere)}) : ""

    valeurs = base(site, page, "")
    valeurs["corps"] = rendre(gabarit("accueil"), {
      "actualite"   => encart,
      "prestations" => cartes.join("\n"),
    })
    valeurs["menu-prestations"] = menu_prestations(prestations, "")
    valeurs["menu-pied"] = menu_pied(prestations, "")

    ecrire("index.html", rendre(gabarit("layout"), valeurs))
  end

  # Une page portant `:menu: pied` va dans le pied de page plutôt que dans le
  # menu des prestations. L'emplacement se décide donc dans le contenu, sans
  # liste de titres à tenir à jour ici.
  def self.au_pied?(page : Source) : Bool
    page.attributs["menu"]? == "pied"
  end

  def self.prestations_du_menu(pages)
    pages.reject { |p| au_pied?(p) }
  end

  def self.pages_du_pied(pages)
    pages.select { |p| au_pied?(p) }
  end

  # Seules les vraies prestations sont proposées dans la liste déroulante du
  # formulaire : « Ma carrière » ou « Actualités » n'en sont pas.
  def self.prestations_demandables(prestations)
    prestations_du_menu(prestations)
  end

  # Chaque prestation devient une page à part entière.
  def self.ecrire_prestation(site, prestations, presta : Source, actualites)
    valeurs = base(site, presta, presta.page)
    # Le texte de la prestation est le corps de la page, pas son chapeau.
    valeurs["intro"] = ""
    # Sans cela l'onglet n'afficherait que « Bornage amiable », sans dire de
    # qui il s'agit — gênant dans une liste de favoris comme sur un moteur.
    valeurs["page-title"] = presta.attributs["page-title"]? ||
                            "#{presta.titre} — #{site["nom"]?}, #{site["fonction"]?}"
    valeurs["page-description"] = presta.attributs["page-description"]? ||
                                  "#{presta.titre} — #{site["nom"]?}, #{site["fonction"]?}."

    # Le lien de fin de page emmène le libellé, que le formulaire relit pour
    # présélectionner la nature de la demande : le visiteur n'a pas à la
    # retrouver dans une liste de huit entrées.
    demandable = prestations_demandables(prestations).any? { |p| p.titre == presta.titre }
    cta_url = demandable ? "contact.html?demande=#{URI.encode_www_form(presta.titre)}" : "contact.html"
    cta_libelle = demandable ? "Demander un devis" : "Me contacter"

    # Les valeurs du bouton sont passées au gabarit de la prestation, et non
    # à celui de la coquille : `rendre` vide tout marqueur qu'il ne connaît
    # pas, si bien qu'un rendu intermédiaire les effacerait.
    contenu = presta.html

    valeurs["corps"] = rendre(gabarit("prestation"), {
      "contenu"     => contenu,
      "cta-url"     => cta_url,
      "cta-libelle" => cta_libelle,
    })
    valeurs["menu-prestations"] = menu_prestations(prestations, presta.page)
    valeurs["menu-pied"] = menu_pied(prestations, presta.page)

    ecrire(presta.page, rendre(gabarit("layout"), valeurs))
  end

  ACTUS_PAR_PAGE_DEFAUT = 10

  def self.actus_par_page(site) : Int32
    taille = (site["actus-par-page"]? || "").to_i?
    taille && taille > 0 ? taille : ACTUS_PAR_PAGE_DEFAUT
  end

  # Adresse d'une page de la liste. La première garde l'adresse d'origine,
  # pour ne pas casser les liens qui la visent déjà.
  def self.page_liste(base_slug : String, numero : Int32) : String
    numero == 1 ? "#{base_slug}.html" : "#{base_slug}-#{numero}.html"
  end

  # Un billet, tel qu'il paraît dans la liste.
  def self.billet_actu(a : Source) : String
    fragment("billet-actu", {
      "date"  => echapper(date_lisible(a.fichier)),
      "lien"  => page_actu(a),
      "titre" => echapper(a.titre),
      "media" => media_actu(a),
      # Sans résumé, le billet montre son texte entier.
      "texte" => a.attributs["resume"]? ? resume_actu(a) : a.html,
    })
  end

  # La pagination ne s'affiche qu'à partir de deux pages : inutile d'encombrer
  # une liste qui tient entière sous les yeux.
  def self.pagination(base_slug : String, courante : Int32, total : Int32) : String
    return "" if total <= 1

    numeros = (1..total).map do |n|
      nom = n == courante ? "page-numero-courante" : "page-numero"
      fragment(nom, {"lien" => page_liste(base_slug, n), "numero" => n.to_s})
    end

    fragment("pagination", {
      "precedente" => courante > 1 ? fragment("page-precedente", {"lien" => page_liste(base_slug, courante - 1)}) : "",
      "suivante"   => courante < total ? fragment("page-suivante", {"lien" => page_liste(base_slug, courante + 1)}) : "",
      "numeros"    => numeros.join('\n'),
    })
  end

  # La page qui rassemble les actualités, découpée en autant de pages que
  # nécessaire. Sans actualité, une seule page, vide de billets.
  def self.ecrire_index_actualites(site, prestations, page : Source, actualites)
    lots = actualites.each_slice(actus_par_page(site)).to_a
    lots = [[] of Source] if lots.empty?
    total = lots.size

    lots.each_with_index do |lot, index|
      numero = index + 1
      chemin = page_liste(page.slug, numero)

      valeurs = base(site, page, chemin)
      valeurs["intro"] = ""
      suffixe = numero == 1 ? "" : " — page #{numero}"
      valeurs["page-title"] = "#{page.titre}#{suffixe} — #{site["nom"]?}, #{site["fonction"]?}"
      valeurs["page-description"] = "#{page.titre} — #{site["nom"]?}, #{site["fonction"]?}."
      valeurs["corps"] = rendre(gabarit("prestation"), {
        "contenu" => page.html + "\n" + lot.map { |a| billet_actu(a) }.join('\n') +
                     "\n" + pagination(page.slug, numero, total),
        "cta-url"     => "contact.html",
        "cta-libelle" => "Me contacter",
      })
      # Toutes les pages de la liste marquent la même entrée du pied.
      valeurs["menu-prestations"] = menu_prestations(prestations, page.page)
      valeurs["menu-pied"] = menu_pied(prestations, page.page)

      ecrire(chemin, rendre(gabarit("layout"), valeurs))
    end
  end

  # Chaque actualité a sa page : c'est elle que vise « Lire la suite ».
  def self.ecrire_actualite(site, prestations, a : Source)
    valeurs = base(site, a, page_actu(a))
    valeurs["intro"] = ""
    valeurs["page-title"] = "#{a.titre} — #{site["nom"]?}, #{site["fonction"]?}"
    valeurs["page-description"] = a.attributs["resume"]? || a.titre
    valeurs["corps"] = rendre(gabarit("prestation"), {
      "contenu" => fragment("actualite", {
        "date"    => echapper(date_lisible(a.fichier)),
        "media"   => media_actu(a),
        "contenu" => a.html,
      }),
      "cta-url"     => "contact.html",
      "cta-libelle" => "Me contacter",
    })
    valeurs["menu-prestations"] = menu_prestations(prestations, page_actu(a))
    valeurs["menu-pied"] = menu_pied(prestations, page_actu(a))

    ecrire(page_actu(a), rendre(gabarit("layout"), valeurs))
  end

  def self.ecrire_contact(site, prestations)
    page = Source.lire(CONTENU / "contact.adoc")

    # La liste déroulante reprend exactement les prestations publiées.
    options = prestations_demandables(prestations).map do |p|
      fragment("option-demande", {"libelle" => echapper(p.titre)})
    end

    # Bandeau facultatif : présent tant que le fichier existe, disparu dès
    # qu'on le supprime. Aucun réglage à retrouver ailleurs.
    fichier_bandeau = CONTENU / "contact-bandeau.adoc"
    bandeau = if File.exists?(fichier_bandeau)
                avis = Source.lire(fichier_bandeau)
                fragment("bandeau", {"titre" => echapper(avis.titre), "contenu" => avis.html})
              else
                ""
              end

    valeurs = base(site, page, "contact.html")
    valeurs["corps"] = rendre(gabarit("contact"), {
      "bandeau"         => bandeau,
      "form-action"     => site["form-action"]? || "https://form.aloli.fr/submit",
      "options-demande" => options.join("\n"),
    })
    valeurs["scripts"] = gabarit("contact-script")
    valeurs["menu-prestations"] = menu_prestations(prestations, "contact.html")
    valeurs["menu-pied"] = menu_pied(prestations, "contact.html")

    ecrire("contact.html", rendre(gabarit("layout"), valeurs))
  end

  def self.ecrire_mentions(site, prestations)
    page = Source.lire(CONTENU / "mentions-legales.adoc")

    # Ici l'intro et le corps viennent du même fichier : le premier paragraphe
    # sert d'introduction, les sections == forment le corps.
    valeurs = base(site, page, "mentions-legales.html")
    valeurs["intro"] = ""
    valeurs["corps"] = rendre(gabarit("mentions-legales"),
      {"contenu" => page.html})
    valeurs["menu-prestations"] = menu_prestations(prestations, "mentions-legales.html")
    valeurs["menu-pied"] = menu_pied(prestations, "mentions-legales.html")

    ecrire("mentions-legales.html", rendre(gabarit("layout"), valeurs))
  end

  def self.copier_statiques
    STATIQUES.each do |entree|
      origine = RACINE / entree
      next unless File.exists?(origine)

      if File.directory?(origine)
        FileUtils.cp_r(origine.to_s, (SORTIE / entree).to_s)
      else
        FileUtils.cp(origine.to_s, (SORTIE / entree).to_s)
      end
    end
  end

  # Le traitement est appliqué à la page entière, et non au seul contenu
  # converti : il couvre ainsi les liens écrits directement dans les gabarits.
  def self.ecrire(nom : String, contenu : String)
    File.write(SORTIE / nom, signaler_liens_externes(contenu))
    puts "   #{nom}"
  end

  # ------------------------------------------------------------ aperçu local

  def self.servir
    serveur = HTTP::Server.new([
      HTTP::LogHandler.new,
      HTTP::StaticFileHandler.new(SORTIE.to_s, directory_listing: false),
    ])
    adresse = serveur.bind_tcp("127.0.0.1", PORT_LOCAL)
    puts "Aperçu sur http://#{adresse} — Ctrl+C pour arrêter."
    serveur.listen
  end
end

Mendoro.generer
Mendoro.servir if ARGV.includes?("--serve")
