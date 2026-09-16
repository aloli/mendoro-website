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

  RACINE    = Path[__DIR__].parent
  CONTENU   = RACINE / "content"
  GABARITS  = RACINE / "templates"
  SORTIE    = RACINE / "_site"
  STATIQUES = %w[css images CNAME]

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

    def initialize(@titre, @attributs, @corps, @slug = "")
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

      slug = File.basename(chemin.to_s, ".adoc").sub(/\A\d+-/, "")
      new(titre, attributs, corps.join('\n').strip, slug)
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
  MENTION_MASQUEE    = %(<span class="visually-hidden"> (nouvelle fenêtre)</span>)

  def self.signaler_liens_externes(html : String) : String
    html.gsub(LIEN_NOUVEL_ONGLET) do |entier, m|
      # Ne pas doubler la mention si le rédacteur l'a déjà écrite lui-même.
      m[2].includes?("visually-hidden") ? entier : "#{m[1]}#{m[2]}#{MENTION_MASQUEE}#{m[3]}"
    end
  end

  # ---------------------------------------------------------------- génération

  def self.generer
    site = Source.lire(CONTENU / "site.adoc").attributs
    prestations = charger_prestations

    FileUtils.rm_rf(SORTIE.to_s)
    Dir.mkdir_p(SORTIE.to_s)

    ecrire_accueil(site, prestations)
    prestations.each { |p| ecrire_prestation(site, prestations, p) }
    ecrire_contact(site, prestations)
    ecrire_mentions(site, prestations)
    copier_statiques

    puts "→ #{SORTIE} (#{prestations.size} prestations)"
  end

  def self.charger_prestations : Array(Source)
    dossier = CONTENU / "prestations"
    Dir.glob("#{dossier}/*.adoc").sort.map { |f| Source.lire(f) }
  end

  # Le rappel des prestations, repris en pied de chaque page. La page
  # affichée porte `aria-current`, que les lecteurs d'écran annoncent et que
  # la feuille de style met en évidence.
  def self.menu_prestations(prestations, chemin_courant : String) : String
    prestations.map do |p|
      courante = p.page == chemin_courant
      marque = courante ? %( aria-current="page") : ""
      %(        <li><a href="#{p.page}"#{marque}>#{echapper(p.titre)}</a></li>)
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

  def self.ecrire_accueil(site, prestations)
    page = Source.lire(CONTENU / "accueil.adoc")

    cartes = prestations.map do |p|
      <<-HTML
            <a class="card" href="#{p.page}">
              <span class="card-titre">#{echapper(p.titre)}</span>
            </a>
      HTML
    end

    valeurs = base(site, page, "")
    valeurs["corps"] = rendre(gabarit("accueil"),
      {"prestations" => cartes.join("\n")})
    valeurs["menu-prestations"] = menu_prestations(prestations, "")

    ecrire("index.html", rendre(gabarit("layout"), valeurs))
  end

  # Prestations proposées dans la liste déroulante du formulaire. « Ma
  # carrière » n'est pas une prestation : on ne la propose pas.
  def self.prestations_demandables(prestations)
    prestations.reject { |p| p.titre == "Ma carrière" }
  end

  # Chaque prestation devient une page à part entière.
  def self.ecrire_prestation(site, prestations, presta : Source)
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
    valeurs["corps"] = rendre(gabarit("prestation"), {
      "contenu"     => presta.html,
      "cta-url"     => cta_url,
      "cta-libelle" => cta_libelle,
    })
    valeurs["menu-prestations"] = menu_prestations(prestations, presta.page)

    ecrire(presta.page, rendre(gabarit("layout"), valeurs))
  end

  def self.ecrire_contact(site, prestations)
    page = Source.lire(CONTENU / "contact.adoc")

    # La liste déroulante reprend exactement les prestations publiées.
    options = prestations_demandables(prestations).map do |p|
      "            <option>#{echapper(p.titre)}</option>"
    end

    valeurs = base(site, page, "contact.html")
    valeurs["corps"] = rendre(gabarit("contact"), {
      "form-action"     => site["form-action"]? || "https://form.aloli.fr/submit",
      "options-demande" => options.join("\n"),
    })
    valeurs["scripts"] = gabarit("contact-script")
    valeurs["menu-prestations"] = menu_prestations(prestations, "contact.html")

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
